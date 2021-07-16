local react_aim = AIAttentionObject.REACT_AIM
local react_combat = AIAttentionObject.REACT_COMBAT

function TankCopLogicAttack.update(data)
	local t = data.t
	local unit = data.unit
	local my_data = data.internal_data

	if my_data.has_old_action then
		CopLogicAttack._upd_stop_old_action(data, my_data)

		return
	end

	if CopLogicIdle._chk_relocate(data) then
		return
	end

	local focus_enemy = data.attention_obj

	if not focus_enemy or focus_enemy.reaction < react_aim then
		CopLogicAttack._upd_enemy_detection(data, true)

		focus_enemy = data.attention_obj
		
		if my_data ~= data.internal_data or not focus_enemy or focus_enemy.reaction < react_aim then
			return
		end
	end

	TankCopLogicAttack._process_pathing_results(data, my_data)

	local enemy_visible = focus_enemy.verified
	local engage = my_data.attitude == "engage"
	local action_taken = my_data.turning or data.unit:movement():chk_action_forbidden("walk") or my_data.walking_to_chase_pos

	if action_taken then
		return
	end

	if unit:anim_data().crouch then
		action_taken = CopLogicAttack._chk_request_action_stand(data)
	end

	if action_taken then
		return
	end

	local enemy_pos = enemy_visible and focus_enemy.m_pos or focus_enemy.verified_pos
	action_taken = CopLogicAttack._chk_request_action_turn_to_enemy(data, my_data, data.m_pos, enemy_pos)

	if action_taken then
		return
	end

	local verified_dis = focus_enemy.verified_dis
	local chase = nil
	local z_dist = math.abs(data.m_pos.z - focus_enemy.m_pos.z)

	if react_combat <= focus_enemy.reaction then
		if enemy_visible then
			if z_dist < 300 or verified_dis > 2000 or engage and verified_dis > 500 then
				chase = true
			end

			if verified_dis < 800 and unit:anim_data().run then
				local new_action = {
					body_part = 2,
					type = "idle"
				}

				data.unit:brain():action_request(new_action)
			end
		elseif z_dist < 300 or verified_dis > 2000 or engage and (not focus_enemy.verified_t or t - focus_enemy.verified_t > 5 or verified_dis > 700) then
			chase = true
		end
	end

	if chase then
		if my_data.walking_to_chase_pos then
			-- Nothing
		elseif my_data.pathing_to_chase_pos then
			-- Nothing
		elseif my_data.chase_path then
			local run_dist = enemy_visible and 1500 or 800
			local walk = verified_dis < run_dist

			TankCopLogicAttack._chk_request_action_walk_to_chase_pos(data, my_data, walk and "walk" or "run")
		elseif my_data.chase_pos then
			my_data.chase_path_search_id = tostring(unit:key()) .. "chase"
			my_data.pathing_to_chase_pos = true
			local to_pos = my_data.chase_pos
			my_data.chase_pos = nil

			data.brain:add_pos_rsrv("path", {
				radius = 60,
				position = mvector3.copy(to_pos)
			})
			unit:brain():search_for_path(my_data.chase_path_search_id, to_pos)
		elseif focus_enemy.nav_tracker then
			my_data.chase_pos = CopLogicAttack._find_flank_pos(data, my_data, focus_enemy.nav_tracker)
		end
	else
		TankCopLogicAttack._cancel_chase_attempt(data, my_data)
	end
end
