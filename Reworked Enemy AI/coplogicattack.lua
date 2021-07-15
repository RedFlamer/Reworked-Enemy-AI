if _G.StreamHeist then
	return
end

local mvec3_copy = mvector3.copy
local react_aim = AIAttentionObject.REACT_AIM
local react_combat = AIAttentionObject.REACT_COMBAT
local react_shoot = AIAttentionObject.REACT_SHOOT

-- Took inspiration from Streamlined Heisting, but further optimized and kept functionality closer to vanilla
function CopLogicAttack._upd_aim( data, my_data )
	local shoot, aim
	local focus_enemy = data.attention_obj
	local verified = focus_enemy and focus_enemy.verified
	local nearly_visible = focus_enemy and focus_enemy.nearly_visible
	local reaction = focus_enemy and focus_enemy.reaction
	local expected_pos = focus_enemy and (focus_enemy.last_verified_pos or focus_enemy.verified_pos)
	
	if focus_enemy and reaction >= react_aim then
		local verified_t = focus_enemy.verified_t
		local time_since_verification = verified_t and data.t - verified_t or 60
		local running = my_data.advancing and not my_data.advancing:stopping() and my_data.advancing:haste() == "run"
		if verified or nearly_visible then
			if reaction >= react_shoot then
				local last_sup_t = data.unit:character_damage():last_suppression_t()
				local vis_ray = focus_enemy.vis_ray
				local verified_dis = focus_enemy.verified_dis
				local weapon_range = running and data.internal_data.weapon_range.close or data.internal_data.weapon_range.optimal
				
				if last_sup_t and (data.t - last_sup_t) < (running and 2.1 or 7) * (verified and 1 or (vis_ray and vis_ray.distance > 500 and 0.5) or 0.2) then
					shoot = true
				elseif verified then
					local criminal_record = focus_enemy.criminal_record
					if verified_dis < weapon_range then
						shoot = true
					elseif criminal_record and criminal_record.assault_t and data.t - criminal_record.assault_t < 2 then
						shoot = true
					end
				elseif my_data.attitude == "engage" and my_data.firing and time_since_verification < 3.5 then
					shoot = true
				end
			end
			
			aim = shoot or focus_enemy.verified_dis < (running and data.internal_data.weapon_range.close or data.internal_data.weapon_range.optimal)
		elseif expected_pos then
			aim = not running or time_since_verification < 3.5
			shoot = aim and my_data.shooting and reaction >= react_shoot and time_since_verification < (running and 2 or 3)
		end
	end
	
	if not aim and data.char_tweak.always_face_enemy and focus_enemy and reaction >= react_combat then
		aim = true
	end
	
	if aim or shoot then
		if verified or nearly_visible then
			if my_data.attention_unit ~= focus_enemy.u_key then
				CopLogicBase._set_attention(data, focus_enemy)
				my_data.attention_unit = focus_enemy.u_key
			end
		elseif expected_pos then
			if my_data.attention_unit ~= expected_pos then
				CopLogicBase._set_attention_on_pos(data, mvec3_copy(expected_pos))
				my_data.attention_unit = mvec3_copy(expected_pos)
			end
		end
		
		if not (my_data.shooting or my_data.spooc_attack or data.unit:anim_data().reload or data.unit:movement():chk_action_forbidden("action")) then
			local shoot_action = {
				type = "shoot",
				body_part = 3
			}
			if data.unit:brain():action_request(shoot_action) then
				my_data.shooting = true
			end
		end
	else
		if (focus_enemy or expected_pos) and data.logic.chk_should_turn(data, my_data) then -- Only turn if we're not going to shoot, copactionshoot handles turning the enemy
			CopLogicAttack._chk_request_action_turn_to_enemy(data, my_data, data.m_pos, expected_pos or (verified or nearly_visible) and focus_enemy.m_pos or expected_pos)
		end
		
		if my_data.shooting then
			local new_action = {type = data.unit:anim_data().reload and "reload" or "idle", body_part = 3}
			data.unit:brain():action_request(new_action)
		end
		
		if my_data.attention_unit then
			CopLogicBase._reset_attention(data)
			my_data.attention_unit = nil
		end
	end
	
	CopLogicAttack.aim_allow_fire( shoot, aim, data, my_data )
end