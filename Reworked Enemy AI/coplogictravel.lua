-- Stop queuing new updates instead of just using our existing ones
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

		if my_data == data.internal_data and not my_data.processing_advance_path and my_data.advance_path then
			CopLogicTravel._chk_begin_advance(data, my_data)

			if my_data.advancing and my_data.path_ahead then
				CopLogicTravel._check_start_path_ahead(data)
			end
		end
	elseif my_data.processing_coarse_path then
		CopLogicTravel._upd_pathing(data, my_data)
	
		if my_data == data.internal_data and not my_data.processing_coarse_path then -- We have received our pathing results
			if objective and (objective.nav_seg or objective.type == "follow") then
				if my_data.coarse_path then -- We received a coarse path
					CopLogicTravel._chk_start_pathing_to_next_nav_point(data, my_data)
				else
					CopLogicTravel._begin_coarse_pathing(data, my_data) -- Still no coarse path, search again
				end
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
		elseif objective and (objective.nav_seg or objective.type == "follow") then -- Normally the logic would shoot itself in the foot and queue another update even though the enemy has hit the timer to be allowed to move, so instead just allow the damn enemy to move
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
		CopLogicBase._exit(data.unit, "idle")

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

function CopLogicTravel._determine_destination_occupation( data, objective )
	local occupation
	if objective.type == "defend_area" then
		if objective.cover then
			occupation = { type = "defend", seg = objective.nav_seg, cover = objective.cover, radius = objective.radius }
		elseif objective.pos then
			occupation = { type = "defend", seg = objective.nav_seg, pos = objective.pos, radius = objective.radius }
		else
			local near_pos = objective.follow_unit and objective.follow_unit:movement():nav_tracker():field_position()
			local cover = CopLogicTravel._find_cover( data, objective.nav_seg, near_pos )
			if cover then
				local cover_entry = { cover }
				occupation = { type = "defend", seg = objective.nav_seg, cover = cover_entry, radius = objective.radius }
			else
				near_pos = CopLogicTravel._get_pos_on_wall( managers.navigation._nav_segments[ objective.nav_seg ].pos, 700 )
				occupation = { type = "defend", seg = objective.nav_seg, pos = near_pos, radius = objective.radius }
			end
		end
	elseif objective.type == "phalanx" then
		local logic = data.unit:brain():get_logic_by_name(objective.type)

		logic.register_in_group_ai(data.unit)

		local phalanx_circle_pos = logic.calc_initial_phalanx_pos(data.m_pos, objective)
		occupation = {
			type = "defend",
			seg = objective.nav_seg,
			pos = phalanx_circle_pos,
			radius = objective.radius
		}
	elseif objective.type == "act" then
		occupation = { type = "act", seg = objective.nav_seg, pos = objective.pos }
	elseif objective.type == "follow" then
		local follow_pos, follow_nav_seg
		local follow_unit_objective = objective.follow_unit:brain() and objective.follow_unit:brain():objective()
		if not follow_unit_objective or follow_unit_objective.in_place or not follow_unit_objective.nav_seg then	-- our follow unit is static
			follow_pos = objective.follow_unit:movement():m_pos()
			follow_nav_seg = objective.follow_unit:movement():nav_tracker():nav_segment()
		else	-- our follow unit is on the move
			follow_pos = follow_unit_objective.pos or objective.follow_unit:movement():m_pos()
			follow_nav_seg = follow_unit_objective.nav_seg
		end
		
		local distance = objective.distance and math.lerp( objective.distance * 0.5, objective.distance, math.random() ) or 700
		local to_pos = CopLogicTravel._get_pos_on_wall( follow_pos, distance )
		occupation = { type = "defend", nav_seg = follow_nav_seg, pos = to_pos }
	elseif objective.type == "revive" then
		local is_local_player = objective.follow_unit:base().is_local_player
		local revive_u_mv = objective.follow_unit:movement()
		local revive_u_tracker = revive_u_mv:nav_tracker()
		local revive_u_rot = is_local_player and Rotation(0, 0, 0) or revive_u_mv:m_rot()
		local revive_u_fwd = revive_u_rot:y()
		local revive_u_right = revive_u_rot:x()
		local revive_u_pos = revive_u_tracker:lost() and revive_u_tracker:field_position() or revive_u_mv:m_pos()
		local ray_params = {
			trace = true,
			tracker_from = revive_u_tracker
		}

		if revive_u_tracker:lost() then
			ray_params.pos_from = revive_u_pos
		end

		local stand_dis = nil

		if is_local_player or objective.follow_unit:base().is_husk_player then
			stand_dis = 120
		else
			stand_dis = 90
			local mid_pos = mvector3.copy(revive_u_fwd)

			mvector3.multiply(mid_pos, -20)
			mvector3.add(mid_pos, revive_u_pos)

			ray_params.pos_to = mid_pos
			local ray_res = managers.navigation:raycast(ray_params)
			revive_u_pos = ray_params.trace[1]
		end

		local rand_side_mul = math.random() > 0.5 and 1 or -1
		local revive_pos = mvector3.copy(revive_u_right)

		mvector3.multiply(revive_pos, rand_side_mul * stand_dis)
		mvector3.add(revive_pos, revive_u_pos)

		ray_params.pos_to = revive_pos
		local ray_res = managers.navigation:raycast(ray_params)

		if ray_res then
			local opposite_pos = mvector3.copy(revive_u_right)

			mvector3.multiply(opposite_pos, -rand_side_mul * stand_dis)
			mvector3.add(opposite_pos, revive_u_pos)

			ray_params.pos_to = opposite_pos
			local old_trace = ray_params.trace[1]
			local opposite_ray_res = managers.navigation:raycast(ray_params)

			if opposite_ray_res then
				if mvector3.distance(revive_pos, revive_u_pos) < mvector3.distance(ray_params.trace[1], revive_u_pos) then
					revive_pos = ray_params.trace[1]
				else
					revive_pos = old_trace
				end
			else
				revive_pos = ray_params.trace[1]
			end
		else
			revive_pos = ray_params.trace[1]
		end

		local revive_rot = revive_u_pos - revive_pos
		local revive_rot = Rotation(revive_rot, math.UP)
		occupation = {
			type = "revive",
			pos = revive_pos,
			rot = revive_rot
		}
	else
		occupation = { seg = objective.nav_seg, pos = objective.pos }
	end
	return occupation
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