local mvec3_set = mvector3.set
local mvec3_set_z = mvector3.set_z
local mvec3_sub = mvector3.subtract
local mvec3_dot = mvector3.dot
local mvec3_norm = mvector3.normalize
local temp_vec1 = Vector3()
local temp_vec2 = Vector3()

function CopLogicAttack._upd_combat_movement( data )
	local my_data = data.internal_data
	local t = data.t
	local unit = data.unit
	local focus_enemy = data.attention_obj
	local in_cover = my_data.in_cover
	local best_cover = my_data.best_cover
	
	local enemy_visible = focus_enemy.verified
	local enemy_visible_soft = focus_enemy.verified_t and t - focus_enemy.verified_t < 2
	local enemy_visible_softer = focus_enemy.verified_t and t - focus_enemy.verified_t < 15
	
	local alert_soft = data.is_suppressed
	
	local action_taken = data.logic.action_taken( data, my_data )
	local want_to_take_cover = my_data.want_to_take_cover
	-- Check if we should crouch or stand
	
	if not action_taken then
		if want_to_take_cover and ( not in_cover or not in_cover[4] ) or ( not data.char_tweak.allowed_poses or data.char_tweak.allowed_poses.stand ) then  -- I do not have cover or my cover is low and I am not crouched
			if not unit:anim_data().crouch then
				action_taken = CopLogicAttack._chk_request_action_crouch( data )
			end
		elseif unit:anim_data().crouch then
			if data.char_tweak.allowed_poses and not data.char_tweak.allowed_poses.crouch or my_data.cover_test_step > 2 then
				action_taken = CopLogicAttack._chk_request_action_stand( data )
			end
		end
	end
	
	local move_to_cover, want_flank_cover	-- "want_flank_cover" means we want to look for a cover that flanks the focus_enemy instead of one closest to us. It's used by _update_cover()
	
	if my_data.cover_test_step ~= 1 and not enemy_visible_softer and ( action_taken or want_to_take_cover or not in_cover ) then
		my_data.cover_test_step = 1 -- reset the "_peek_for_pos_sideways" check
	end
	
	if my_data.stay_out_time and ( enemy_visible_soft or not my_data.at_cover_shoot_pos or action_taken or want_to_take_cover ) then
		my_data.stay_out_time = nil -- reset how long we may wait for the enemy to appear on its own
	elseif my_data.attitude == "engage" and not my_data.stay_out_time and not enemy_visible_soft and my_data.at_cover_shoot_pos and not ( action_taken or want_to_take_cover ) then
		my_data.stay_out_time = t + 7
	end
	
	-- check if we should move somewhere
	if action_taken then
	elseif want_to_take_cover then -- we don't want trouble
		move_to_cover = true
	elseif not enemy_visible_soft then -- we want trouble and haven't seen our enemy recently
		if data.tactics and data.tactics.charge and data.objective and data.objective.grp_objective and data.objective.grp_objective.charge and ( not my_data.charge_path_failed_t or data.t - my_data.charge_path_failed_t > 6 ) then
			if my_data.charge_path then
				local path = my_data.charge_path
				my_data.charge_path = nil
				action_taken = CopLogicAttack._chk_request_action_walk_to_cover_shoot_pos( data, my_data, path )
			elseif not my_data.charge_path_search_id and data.attention_obj.nav_tracker then
				my_data.charge_pos = CopLogicTravel._get_pos_on_wall( data.attention_obj.nav_tracker:field_position(), my_data.weapon_range.optimal, 45, nil )
				if my_data.charge_pos then
					my_data.charge_path_search_id = "charge"..tostring(data.key)
					unit:brain():search_for_path( my_data.charge_path_search_id, my_data.charge_pos, nil, nil, nil )
					--debug_pause_unit( data.unit, "decided to charge", data.unit )
				else
					debug_pause_unit( data.unit, "failed to find charge_pos", data.unit )
					my_data.charge_path_failed_t = TimerManager:game():time()
				end
			end
		elseif in_cover then
			if my_data.cover_test_step <= 2 then -- peek sideways for a line of fire
				local height
				if in_cover[4] then
					height = 150
				else
					height = 80
				end
				
				local my_tracker = unit:movement():nav_tracker()
				local shoot_from_pos = CopLogicAttack._peek_for_pos_sideways( data, my_data, my_tracker, focus_enemy.m_head_pos, height )
				
				if shoot_from_pos then
					local path = { my_tracker:position(), shoot_from_pos }
					action_taken = CopLogicAttack._chk_request_action_walk_to_cover_shoot_pos( data, my_data, path, math.random() < 0.5 and "run" or "walk" )
				else
					my_data.cover_test_step = my_data.cover_test_step + 1
				end
			elseif not enemy_visible_softer then -- we are in cover and haven't found a suitable peek position in a long time. find new cover
				if math.random() < 0.05 then
					move_to_cover = true
					want_flank_cover = true -- turn on the flanking algorithm
				end
			end
		else -- not in_cover
			if my_data.walking_to_cover_shoot_pos then -- Moving out of cover to fire
			elseif my_data.at_cover_shoot_pos then -- we stand beside our cover in hope of getting a line of fire
				if my_data.stay_out_time < t then -- wait a few seconds in case the enemy pops up
					move_to_cover = true
				end
			else
				move_to_cover = true
			end
		end
	end
	
	if not ( my_data.processing_cover_path or my_data.cover_path or my_data.charge_path_search_id or action_taken )
	and best_cover
	and ( not in_cover or best_cover[1] ~= in_cover[1] ) 
	and ( not my_data.cover_path_failed_t or data.t - my_data.cover_path_failed_t > 5 ) then
		CopLogicAttack._cancel_cover_pathing( data, my_data )
		local search_id = tostring( unit:key() ).."cover"
		if data.unit:brain():search_for_path_to_cover( search_id, best_cover[1], best_cover[5] ) then
			my_data.cover_path_search_id = search_id
			my_data.processing_cover_path = best_cover
		end
	end
	
	if not action_taken and move_to_cover and my_data.cover_path then
		action_taken = CopLogicAttack._chk_request_action_walk_to_cover( data, my_data )
	end
	
	
	if want_flank_cover then
		if not my_data.flank_cover then
			local sign = math.random() < 0.5 and -1 or 1
			local step = 30
			my_data.flank_cover = { step = step, angle = step * sign, sign = sign }
		end
	else
		my_data.flank_cover = nil
	end
	
	-- my_data.flank_cover = nil
	
	if not ( my_data.turning or data.unit:movement():chk_action_forbidden( "walk" ) ) and CopLogicAttack._can_move( data ) then
		
		if data.attention_obj.verified and not ( in_cover and in_cover[4] ) then
			if data.is_suppressed and data.t - data.unit:character_damage():last_suppression_t() < 0.7 then -- suppressed and recently received fire
				--print( "suppressed" )
				action_taken = CopLogicBase.chk_start_action_dodge( data, "scared" )
			end
			
			if not action_taken and focus_enemy.is_person and focus_enemy.dis < 2000 and ( ( data.group and data.group.size > 1 ) or math.random() < 0.5 ) then
				--print( "is_person" )
				local dodge
				if focus_enemy.is_local_player then
					local e_movement_state = focus_enemy.unit:movement():current_state()
					if not ( e_movement_state:_is_reloading() or e_movement_state:_interacting() or e_movement_state:is_equipping() ) then
						--print( "not threatened1" )
						dodge = true
					end
				else
					local e_anim_data = focus_enemy.unit:anim_data()
					if ( e_anim_data.move or e_anim_data.idle ) and not e_anim_data.reload then
						--print( "not threatened2" )
						dodge = true
					end
				end
				
				if dodge then
					--print( "threatened" )
					if focus_enemy.aimed_at then
						--print( "in cone!" )
						--Application:set_pause( true )
						action_taken = CopLogicBase.chk_start_action_dodge( data, "preemptive" )
					end
				end
			end
		end
	--else
		--print( "action taken" )
	end
	
	-- Check should we hastily retreat from our focus enemy?
	if not action_taken and want_to_take_cover and not best_cover then
		action_taken = CopLogicAttack._chk_start_action_move_back( data, my_data, focus_enemy, false )
	end
	
	if not action_taken then
		action_taken = CopLogicAttack._chk_start_action_move_out_of_the_way( data, my_data )
	end
end

function CopLogicAttack._upd_aim( data, my_data )
	local shoot, aim, expected_pos
	local focus_enemy = data.attention_obj
	if focus_enemy and focus_enemy.reaction >= AIAttentionObject.REACT_AIM then	-- I have an enemy
		local last_sup_t = data.unit:character_damage():last_suppression_t()
		
		if focus_enemy.verified or focus_enemy.nearly_visible then
			if data.unit:anim_data().run and focus_enemy.dis > math.lerp( my_data.weapon_range.close, my_data.weapon_range.optimal, 0 ) then	-- sprinting. do not shoot if running sideways
				local walk_to_pos = data.unit:movement():get_walk_to_pos()
				if walk_to_pos then
					mvector3.direction( temp_vec1, data.m_pos, walk_to_pos )
					mvector3.direction( temp_vec2, data.m_pos, focus_enemy.m_pos )
					local dot = mvector3.dot( temp_vec1, temp_vec2 )
					if dot < 0.6 then
						shoot = false
						aim = false
					end
				end
			end
			if aim == nil and focus_enemy.reaction >= AIAttentionObject.REACT_AIM then
				if focus_enemy.reaction >= AIAttentionObject.REACT_SHOOT then
					local running = my_data.advancing and not my_data.advancing:stopping() and my_data.advancing:haste() == "run"
					
					
					if last_sup_t and ( data.t - last_sup_t ) < ( 7 * ( running and 0.3 or 1 ) ) * ( focus_enemy.verified and 1 or ( focus_enemy.vis_ray and focus_enemy.vis_ray.distance > 500 and 0.5 ) or 0.2 ) then
						shoot = true
					elseif focus_enemy.verified and focus_enemy.verified_dis < data.internal_data.weapon_range.close then
						if focus_enemy.aimed_at or not focus_enemy.is_human_player then
							shoot = true
						else
							aim = true
						end
					elseif focus_enemy.verified and focus_enemy.criminal_record and focus_enemy.criminal_record.assault_t and data.t - focus_enemy.criminal_record.assault_t < 2 then
						shoot = true
					end
					
					
					if not shoot and my_data.attitude == "engage" then
						if focus_enemy.verified then
							if ( focus_enemy.verified_dis < ( running and data.internal_data.weapon_range.close or data.internal_data.weapon_range.far ) or focus_enemy.reaction == AIAttentionObject.REACT_SHOOT ) then
								shoot = true
							end
						else
							local time_since_verification = focus_enemy.verified_t and ( data.t - focus_enemy.verified_t )
							if my_data.firing and time_since_verification and time_since_verification < 3.5 then
								shoot = true
							end
						end
					end
					
					aim = aim or shoot
					
					if not aim and focus_enemy.verified_dis < ( running and data.internal_data.weapon_range.close or data.internal_data.weapon_range.far ) then
						aim = true
					end
				else
					aim = true
				end
			end
		elseif focus_enemy.reaction >= AIAttentionObject.REACT_AIM then
			local time_since_verification = focus_enemy.verified_t and data.t - focus_enemy.verified_t
			local running = my_data.advancing and not my_data.advancing:stopping() and my_data.advancing:haste() == "run"
			local same_z = math.abs( focus_enemy.verified_pos.z - data.m_pos.z ) < 250
			
			if running then
				if time_since_verification and time_since_verification < math.lerp( 5, 1, math.max( 0, focus_enemy.verified_dis - 500 ) / 600 ) then
					aim = true
				end
			else
				aim = true
			end
			
			if aim and my_data.shooting and ( focus_enemy.reaction >= AIAttentionObject.REACT_SHOOT ) and time_since_verification and ( time_since_verification < ( running and 2 or 3 ) ) then
				shoot = true
			end
			
			if not aim then
				expected_pos = CopLogicAttack._get_expected_attention_position( data, my_data )
				if expected_pos then
					if running then
						local watch_dir = temp_vec1
						mvec3_set( watch_dir, expected_pos )
						mvec3_sub( watch_dir, data.m_pos )
						mvec3_set_z( watch_dir, 0 )
						local watch_pos_dis = mvec3_norm( watch_dir )
						
						local walk_to_pos = data.unit:movement():get_walk_to_pos()
						local walk_vec = temp_vec2
						mvec3_set( walk_vec, walk_to_pos )
						mvec3_sub( walk_vec, data.m_pos )
						mvec3_set_z( walk_vec, 0 )
						mvec3_norm( walk_vec )
						
						local watch_walk_dot = mvec3_dot( watch_dir, walk_vec )
						if watch_pos_dis < 500 or watch_pos_dis < 1000 and watch_walk_dot > 0.85 then
							aim = true
						end
					else
						aim = true
					end
				end
			end
		else
			expected_pos = CopLogicAttack._get_expected_attention_position( data, my_data )
			if expected_pos then
				aim = true
			end
		end
	end
	
	if not aim and data.char_tweak.always_face_enemy and focus_enemy and focus_enemy.reaction >= AIAttentionObject.REACT_COMBAT then
		aim = true
	end
	
	if data.logic.chk_should_turn( data, my_data ) then
		if focus_enemy or expected_pos then
			local enemy_pos = expected_pos or ( focus_enemy.verified or focus_enemy.nearly_visible ) and focus_enemy.m_pos or focus_enemy.verified_pos
			CopLogicAttack._chk_request_action_turn_to_enemy( data, my_data, data.m_pos, enemy_pos )
		end
	end
	
	if aim or shoot then
		if expected_pos then
			if my_data.attention_unit ~= expected_pos then
				CopLogicBase._set_attention_on_pos( data, mvector3.copy( expected_pos ) )
				my_data.attention_unit = mvector3.copy( expected_pos )
			end
		elseif focus_enemy.verified or focus_enemy.nearly_visible then
			if my_data.attention_unit ~= focus_enemy.u_key then
				CopLogicBase._set_attention( data, focus_enemy )
				my_data.attention_unit = focus_enemy.u_key
			end
		else
			local look_pos = focus_enemy.last_verified_pos or focus_enemy.verified_pos
			if my_data.attention_unit ~= look_pos then
				CopLogicBase._set_attention_on_pos( data, mvector3.copy( look_pos ) )
				my_data.attention_unit = mvector3.copy( look_pos )
			end
		end
		
		if not ( my_data.shooting or my_data.spooc_attack or data.unit:anim_data().reload or data.unit:movement():chk_action_forbidden( "action" ) ) then
			local shoot_action = {
				type = "shoot",
				body_part = 3
			}
			if data.unit:brain():action_request( shoot_action ) then
				my_data.shooting = true
			end
		end
	else		-- do not aim ( switch to hostile stance )
		if my_data.shooting then
			local new_action
			if data.unit:anim_data().reload then
				new_action = { type = "reload", body_part = 3 }
			else
				new_action = { type = "idle", body_part = 3 }
			end
			data.unit:brain():action_request( new_action )
		end
		if my_data.attention_unit then
			CopLogicBase._reset_attention( data )
			my_data.attention_unit = nil
		end
	end
	
	CopLogicAttack.aim_allow_fire( shoot, aim, data, my_data )
end