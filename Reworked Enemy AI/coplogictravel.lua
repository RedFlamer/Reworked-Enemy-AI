local math_abs = math.abs

local mvec3_cpy = mvector3.copy

-- Stop queuing new updates if we're already ready to move, why should an enemy have to queue another update to move if their cover wait time has expired?
-- If an enemy receives their pathing results just fucking use them
function CopLogicTravel.upd_advance(data)
	local unit = data.unit
	local my_data = data.internal_data
	local objective = data.objective
	local t = TimerManager:game():time()
	data.t = t

	if my_data.has_old_action then
		CopLogicAttack._upd_stop_old_action(data, my_data)
	elseif my_data.warp_pos then
		local action_desc = {
			body_part = 1,
			type = "warp",
			position = mvector3.copy(objective.pos),
			rotation = objective.rot
		}

		if unit:movement():action_request(action_desc) then
			CopLogicTravel._on_destination_reached(data)
		end
	elseif my_data.advancing then
		if my_data.coarse_path then
			if my_data.announce_t and my_data.announce_t < t then
				CopLogicTravel._try_anounce(data, my_data)
			end

			CopLogicTravel._chk_stop_for_follow_unit(data, my_data)

			if my_data ~= data.internal_data then
				return
			end
		end
	elseif my_data.advance_path then
		CopLogicTravel._chk_begin_advance(data, my_data)

		if my_data.advancing and my_data.path_ahead then
			CopLogicTravel._check_start_path_ahead(data)
		end
	elseif my_data.processing_advance_path then
		CopLogicTravel._upd_pathing(data, my_data)

		if my_data == data.internal_data and not my_data.processing_advance_path and my_data.advance_path then -- We have received our pathing results
			CopLogicTravel._chk_begin_advance(data, my_data)

			if my_data.advancing and my_data.path_ahead then
				CopLogicTravel._check_start_path_ahead(data)
			end
		end
	elseif my_data.processing_coarse_path then
		CopLogicTravel._upd_pathing(data, my_data)
	
		if my_data == data.internal_data and not my_data.processing_coarse_path then -- We have received our pathing results
			if my_data.coarse_path then
				CopLogicTravel._chk_start_pathing_to_next_nav_point(data, my_data)
			else
				CopLogicTravel._begin_coarse_pathing(data, my_data)
			end
		end
	elseif my_data.cover_leave_t then
		if not unit:movement():chk_action_forbidden("walk") and not data.unit:anim_data().reload and my_data.cover_leave_t < t then
			my_data.cover_leave_t = nil
		end
		
		if my_data.cover_leave_t then
			if data.attention_obj and AIAttentionObject.REACT_COMBAT <= data.attention_obj.reaction and (not my_data.best_cover or not my_data.best_cover[4]) and not unit:anim_data().crouch and (not data.char_tweak.allowed_poses or data.char_tweak.allowed_poses.crouch) then
				CopLogicAttack._chk_request_action_crouch(data)
			end
		elseif objective and (objective.nav_seg or objective.type == "follow") then -- Normally the logic would shoot itself in the foot and queue another update before letting the enemy move, so instead just allow the damn enemy to move
			if my_data.coarse_path then
				if my_data.coarse_path_index == #my_data.coarse_path then
					CopLogicTravel._on_destination_reached(data)

					return
				else
					CopLogicTravel._chk_start_pathing_to_next_nav_point(data, my_data)
				end
			else
				CopLogicTravel._begin_coarse_pathing(data, my_data)
			end
		else
			CopLogicBase._exit(data.unit, data.logic._get_logic_state_from_reaction(data) or "idle") -- Could be a scenario where we have finished our objective, but a criminal has appeared

			return
		end
	elseif objective and (objective.nav_seg or objective.type == "follow") then
		if my_data.coarse_path then
			if my_data.coarse_path_index == #my_data.coarse_path then
				CopLogicTravel._on_destination_reached(data)

				return
			else
				CopLogicTravel._chk_start_pathing_to_next_nav_point(data, my_data)
			end
		else
			CopLogicTravel._begin_coarse_pathing(data, my_data)
		end
	else
		CopLogicBase._exit(data.unit, data.logic._get_logic_state_from_reaction(data) or "idle") -- Could be a scenario where we have finished our objective, but a criminal has appeared

		return
	end
end

function CopLogicTravel._update_cover( ignore_this, data )
	--print( "CopLogicTravel._update_cover", data.t )
	local my_data = data.internal_data
	CopLogicBase.on_delayed_clbk( my_data, my_data.cover_update_task_key )
	
	local cover_release_dis = 100
	local nearest_cover = my_data.nearest_cover
	local best_cover = my_data.best_cover
	local m_pos = data.m_pos
	
	if not my_data.in_cover and nearest_cover and mvector3.distance( nearest_cover[1][1], m_pos ) > cover_release_dis	then -- I dont want cover and have one
		managers.navigation:release_cover( nearest_cover[1] )
		my_data.nearest_cover = nil
		nearest_cover = nil
	end
	if best_cover and mvector3.distance( best_cover[1][1], m_pos ) > cover_release_dis	then -- I dont want cover and have one
		managers.navigation:release_cover( best_cover[1] )
		my_data.best_cover = nil
		best_cover = nil
	end
	
	if nearest_cover or best_cover then
		CopLogicBase.add_delayed_clbk( my_data, my_data.cover_update_task_key, callback( CopLogicTravel, CopLogicTravel, "_update_cover", data ), data.t + 1 )
	end
end

function CopLogicTravel.action_complete_clbk( data, action )
	--print( "CopLogicTravel.action_complete_clbk", action:type() )
	local my_data = data.internal_data
	local action_type = action:type()
	if action_type == "walk" then
		if action:expired() and not my_data.starting_advance_action and my_data.coarse_path_index and not my_data.has_old_action and my_data.advancing then	-- Action has terminated normally ( was not interrupted )
			my_data.coarse_path_index = my_data.coarse_path_index + 1
			if my_data.coarse_path_index > #my_data.coarse_path then
				debug_pause_unit( data.unit, "[CopLogicTravel.action_complete_clbk] invalid coarse path index increment", inspect( my_data.coarse_path ), my_data.coarse_path_index )
				my_data.coarse_path_index = my_data.coarse_path_index - 1
			end
		end
		
		my_data.advancing = nil
		
		if my_data.moving_to_cover then
			if action:expired() then	-- Action has terminated normally ( was not interrupted )
				if my_data.best_cover then	-- We are leaving our old cover
					managers.navigation:release_cover( my_data.best_cover[1] )
				end
				my_data.best_cover = my_data.moving_to_cover
				
				CopLogicBase.chk_cancel_delayed_clbk( my_data, my_data.cover_update_task_key )
				
				local high_ray = CopLogicTravel._chk_cover_height( data, my_data.best_cover[1], data.visibility_slotmask )
				my_data.best_cover[4] = high_ray
				my_data.in_cover = true
				local cover_wait_t = my_data.cover_wait_t or { 0.7, 0.8 } -- 0.7 to 1.5
				my_data.cover_leave_t = data.t + cover_wait_t[1] + cover_wait_t[2] * math.random()
			else
				managers.navigation:release_cover( my_data.moving_to_cover[1] )
				if my_data.best_cover then	-- We are leaving our old cover
					local dis = mvector3.distance( my_data.best_cover[1][1], data.unit:movement():m_pos() )
					if dis > 100 then
						managers.navigation:release_cover( my_data.best_cover[1] )
						my_data.best_cover = nil
					end
				end
			end
			my_data.moving_to_cover = nil
		else
			if my_data.best_cover then	-- We are leaving our old cover
				local dis = mvector3.distance( my_data.best_cover[1][1], data.unit:movement():m_pos() )
				if dis > 100 then
					managers.navigation:release_cover( my_data.best_cover[1] )
					my_data.best_cover = nil
				end
			end
		end
	elseif action_type == "turn" then
		data.internal_data.turning = nil
	elseif action_type == "shoot" then
		data.internal_data.shooting = nil
	elseif action_type == "dodge" then
		local objective = data.objective
		local allow_trans, obj_failed = CopLogicBase.is_obstructed( data, objective, nil, nil )
		if allow_trans then
			local wanted_state = data.logic._get_logic_state_from_reaction( data )
			if wanted_state and wanted_state ~= data.name then
				if obj_failed then
					if data.unit:in_slot( managers.slot:get_mask( "enemies" ) ) or data.unit:in_slot( 17 ) then
						managers.groupai:state():on_objective_failed( data.unit, data.objective )
					elseif data.unit:in_slot( managers.slot:get_mask( "criminals" ) ) then
						managers.groupai:state():on_criminal_objective_failed( data.unit, data.objective, false )
					end
					
					if my_data == data.internal_data then -- if we haven't changed state already, change now
						debug_pause_unit( data.unit, "[CopLogicTravel.action_complete_clbk] exiting without discarding objective", data.unit, inspect( data.objective ) )
						CopLogicBase._exit( data.unit, wanted_state )
					end
				end
			end
		end
	end
end

function CopLogicTravel.chk_group_ready_to_move( data, my_data )
	-- check that the people in my group who have a similar objective to mine have caught up with me
	local my_objective = data.objective
	if not my_objective.grp_objective then
		return true -- This is not a group objective. do not wait
	end
	local my_dis = mvector3.distance_sq( my_objective.area.pos, data.m_pos )
	if my_dis > 2000*2000 then -- do not wait for anybody if we are further than 20m away
		return true
	end
	
	my_dis = my_dis * 1.15 * 1.15 -- 15% tolerance
	
	for u_key, u_data in pairs( data.group.units ) do
		if u_key ~= data.key then
			local his_objective = u_data.unit:brain():objective()
			if his_objective and his_objective.grp_objective == my_objective.grp_objective and not his_objective.in_place then
				local his_dis = mvector3.distance_sq( his_objective.area.pos, u_data.m_pos )
				if my_dis < his_dis then
					--[[debug_pause_unit( data.unit, "[CopLogicTravel.chk_group_ready_to_move] waiting", data.unit, u_data.unit )
					Application:draw_cone( u_data.m_pos, data.m_pos, 30, 1,0,0 )
					Application:draw_cylinder( my_objective.area.pos, data.m_pos, 20, 0,0,1 )]]
					return false
				end
			end
		end
	end
	
	return true
end

function CopLogicTravel._check_start_path_ahead(data)
	local my_data = data.internal_data

	if my_data.processing_advance_path then
		return
	end

	local objective = data.objective
	local coarse_path = my_data.coarse_path
	local next_index = my_data.coarse_path_index + 2
	local total_nav_points = #coarse_path

	if next_index > total_nav_points then
		return
	end

	local from_pos = data.pos_rsrv.move_dest.position
	local to_pos = data.logic._get_exact_move_pos(data, next_index)
	
	if math_abs(from_pos.z - to_pos.z) < 100 and not managers.navigation:raycast({allow_entry = false, pos_from = from_pos, pos_to = to_pos}) then
		-- Less than 1m height difference, and no obstructions, don't bother searching for a path and just go
		-- If this has issues due to height difference, remember to change the value in copactionwalk too
		my_data.advance_path = {
			mvec3_cpy(from_pos),
			to_pos
		}

		CopLogicTravel._chk_begin_advance(data, my_data)

		if my_data.advancing and my_data.path_ahead then
			CopLogicTravel._check_start_path_ahead(data)
		end
		
		return
	end	
	
	my_data.processing_advance_path = true
	local prio = data.logic.get_pathing_prio(data)
	local nav_segs = CopLogicTravel._get_allowed_travel_nav_segs(data, my_data, to_pos)

	data.unit:brain():search_for_path_from_pos(my_data.advance_path_search_id, from_pos, to_pos, prio, nil, nav_segs)
end

function CopLogicTravel._chk_start_pathing_to_next_nav_point(data, my_data)
	if not CopLogicTravel.chk_group_ready_to_move(data, my_data) then
		return
	end

	local from_pos = data.unit:movement():nav_tracker():field_position()
	local to_pos = CopLogicTravel._get_exact_move_pos(data, my_data.coarse_path_index + 1)

	if math_abs(from_pos.z - to_pos.z) < 100 and not managers.navigation:raycast({allow_entry = false, pos_from = from_pos, pos_to = to_pos}) then
		-- Less than 1m height difference, and no obstructions, don't bother searching for a path and just go
		-- If this has issues due to height difference, remember to change the value in copactionwalk too
		my_data.advance_path = {
			mvec3_cpy(from_pos),
			to_pos
		}

		CopLogicTravel._chk_begin_advance(data, my_data)

		if my_data.advancing and my_data.path_ahead then
			CopLogicTravel._check_start_path_ahead(data)
		end
		
		return
	end
	
	my_data.processing_advance_path = true
	local prio = data.logic.get_pathing_prio(data)
	local nav_segs = CopLogicTravel._get_allowed_travel_nav_segs(data, my_data, to_pos)

	data.unit:brain():search_for_path(my_data.advance_path_search_id, to_pos, prio, nil, nav_segs)
end