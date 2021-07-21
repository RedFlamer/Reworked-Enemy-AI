local math_abs = math.abs
local math_clamp = math.clamp
local math_lerp = math.lerp
local math_min = math.min
local math_up = math.UP

local mvec3_add = mvector3.add
local mvec3_angle = mvector3.angle
local mvec3_cpy = mvector3.copy
local mvec3_cross = mvector3.cross
local mvec3_dir = mvector3.direction
local mvec3_dis = mvector3.distance
local mvec3_dot = mvector3.dot
local mvec3_multiply = mvector3.multiply
local mvec3_set = mvector3.set
local mvec3_set_length = mvector3.set_length
local mvec3_set_z = mvector3.set_z
local mvec3_sub = mvector3.subtract

local tmp_vec1 = Vector3()

local react_combat = AIAttentionObject.REACT_COMBAT
local react_scared = AIAttentionObject.REACT_SCARED
local react_suspicious = AIAttentionObject.REACT_SUSPICIOUS

function CopLogicBase._upd_attention_obj_detection(data, min_reaction, max_reaction)
	local t = data.t
	local detected_obj = data.detected_attention_objects
	local my_data = data.internal_data
	local my_key = data.key
	local my_pos = data.unit:movement():m_head_pos()
	local my_access = data.SO_access
	local all_attention_objects = managers.groupai:state():get_AI_attention_objects_by_filter(data.SO_access_str, data.team)
	local my_head_fwd = nil
	local my_tracker = data.unit:movement():nav_tracker()
	local chk_vis_func = my_tracker.check_visibility
	local is_detection_persistent = managers.groupai:state():is_detection_persistent()
	local delay = 2
	local player_importance_wgt = data.unit:in_slot(managers.slot:get_mask("enemies")) and {}

	for u_key, attention_info in pairs(all_attention_objects) do
		if u_key ~= my_key and not detected_obj[u_key] and (not attention_info.nav_tracker or chk_vis_func(my_tracker, attention_info.nav_tracker)) then
			local handler = attention_info.handler
			local settings = handler:get_attention(my_access, min_reaction, max_reaction, data.team)

			if settings then
				local angle, angle_multiplier, dis_multiplier, acquired = nil
				local attention_pos = handler:get_detection_m_pos()
				local dis = mvec3_dir(tmp_vec1, my_pos, attention_pos)
				local detection = my_data.detection

				if settings.uncover_range and detection.use_uncover_range and dis < settings.uncover_range then
					angle = -1
					dis_multiplier = 0
				else
					local temp_dis_multiplier = nil
					local max_dis = math_min(detection.dis_max, settings.max_range or detection.dis_max)
					local settings_det = settings.detection
					
					if settings_det and settings_det.range_mul then
						max_dis = max_dis * settings_det.range_mul
					end
					
					temp_dis_multiplier = dis / max_dis
			
					if temp_dis_multiplier < 1 then
						if settings.notice_requires_FOV then
							my_head_fwd = data.unit:movement():m_head_rot():z()
							local temp_angle = mvec3_angle(my_head_fwd, tmp_vec1)

							if temp_angle < 55 and not detection.use_uncover_range and settings.uncover_range and dis < settings.uncover_range then
								angle = -1
								dis_multiplier = 0
							end

							local angle_max = math_lerp(180, detection.angle_max, math_clamp((dis - 150) / 700, 0, 1))
							angle_multiplier = temp_angle / angle_max

							if angle_multiplier < 1 then
								angle = temp_angle
								dis_multiplier = temp_dis_multiplier
							end
						else
							angle = 0
							dis_multiplier = temp_dis_multiplier
						end
					end
				end

				if angle then
					local vis_ray = World:raycast("ray", my_pos, attention_pos, "slot_mask", data.visibility_slotmask, "ray_type", "ai_vision")

					if not vis_ray or vis_ray.unit:key() == u_key then
						acquired = true
						detected_obj[u_key] = CopLogicBase._create_detected_attention_object_data(data.t, data.unit, u_key, attention_info, settings)
					end
				end

				if not acquired and player_importance_wgt then
					local is_human_player, is_local_player, is_husk_player = nil

					if attention_info.unit:base() then
						is_local_player = attention_info.unit:base().is_local_player
						is_husk_player = not is_local_player and attention_info.unit:base().is_husk_player
						is_human_player = is_local_player or is_husk_player
					end

					if is_human_player then
						local weight = mvec3_dir(tmp_vec1, attention_pos, my_pos)
						local e_fwd = nil

						if is_husk_player then
							e_fwd = attention_info.unit:movement():detect_look_dir()
						else
							e_fwd = attention_info.unit:movement():m_head_rot():y()
						end

						local dot = mvec3_dot(e_fwd, tmp_vec1)
						weight = weight * weight * (1 - dot)

						player_importance_wgt[#player_importance_wgt + 1] = u_key
						player_importance_wgt[#player_importance_wgt + 1] = weight
					end
				end
			end
		end
	end

	for u_key, attention_info in pairs(detected_obj) do
		if t < attention_info.next_verify_t then
			if react_suspicious <= attention_info.reaction then
				delay = math_min(attention_info.next_verify_t - t, delay)
			end
		else
			attention_info.next_verify_t = t + (attention_info.identified and attention_info.verified and attention_info.settings.verification_interval or attention_info.settings.notice_interval or attention_info.settings.verification_interval)
			delay = math_min(delay, attention_info.settings.verification_interval)

			if not attention_info.identified then
				local angle, dis_multiplier, noticable = nil
				local attention_pos = attention_info.m_head_pos
				local dis = mvec3_dir(tmp_vec1, my_pos, attention_pos)
				local detection = my_data.detection
				local settings = attention_info.settings

				if settings.uncover_range and detection.use_uncover_range and dis < settings.uncover_range then
					angle = -1
					dis_multiplier = 0
				else
					local temp_dis_multiplier, angle_multiplier = nil
					local max_dis = math_min(detection.dis_max, settings.max_range or detection.dis_max)
					local settings_det = settings.detection
					
					if settings_det and settings_det.range_mul then
						max_dis = max_dis * settings_det.range_mul
					end
					
					temp_dis_multiplier = dis / max_dis
			
					if temp_dis_multiplier < 1 then
						if settings.notice_requires_FOV then
							my_head_fwd = data.unit:movement():m_head_rot():z()
							local temp_angle = mvec3_angle(my_head_fwd, tmp_vec1)

							if temp_angle < 55 and not detection.use_uncover_range and settings.uncover_range and dis < settings.uncover_range then
								angle = -1
								dis_multiplier = 0
							end

							local angle_max = math_lerp(180, detection.angle_max, math_clamp((dis - 150) / 700, 0, 1))
							angle_multiplier = temp_angle / angle_max

							if angle_multiplier < 1 then
								angle = temp_angle
								dis_multiplier = temp_dis_multiplier
							end
						else
							angle = 0
							dis_multiplier = temp_dis_multiplier
						end
					end
				end

				if angle then
					local attention_pos = attention_info.handler:get_detection_m_pos()
					local vis_ray = World:raycast("ray", my_pos, attention_pos, "slot_mask", data.visibility_slotmask, "ray_type", "ai_vision")

					if not vis_ray or vis_ray.unit:key() == u_key then
						noticable = true
					end
				end

				local delta_prog = nil
				local dt = t - attention_info.prev_notice_chk_t

				if noticable then
					if angle == -1 then
						delta_prog = 1
					else
						local min_delay = my_data.detection.delay[1]
						local max_delay = my_data.detection.delay[2]
						local angle_mul_mod = 0.25 * math_min(angle / my_data.detection.angle_max, 1)
						local dis_mul_mod = 0.75 * dis_multiplier
						local notice_delay_mul = attention_info.settings.notice_delay_mul or 1

						if attention_info.settings.detection and attention_info.settings.detection.delay_mul then
							notice_delay_mul = notice_delay_mul * attention_info.settings.detection.delay_mul
						end

						local notice_delay_modified = math_lerp(min_delay * notice_delay_mul, max_delay, dis_mul_mod + angle_mul_mod)
						delta_prog = notice_delay_modified > 0 and dt / notice_delay_modified or 1
					end
				else
					delta_prog = dt * -0.125
				end

				attention_info.notice_progress = attention_info.notice_progress + delta_prog

				if attention_info.notice_progress > 1 then
					attention_info.notice_progress = nil
					attention_info.prev_notice_chk_t = nil
					attention_info.identified = true
					attention_info.release_t = t + attention_info.settings.release_delay
					attention_info.identified_t = t
					noticable = true

					data.logic.on_attention_obj_identified(data, u_key, attention_info)
				elseif attention_info.notice_progress < 0 then
					CopLogicBase._destroy_detected_attention_object_data(data, attention_info)

					noticable = false
				else
					noticable = attention_info.notice_progress
					attention_info.prev_notice_chk_t = t

					if data.cool and react_scared <= attention_info.settings.reaction then
						managers.groupai:state():on_criminal_suspicion_progress(attention_info.unit, data.unit, noticable)
					end
				end

				if noticable ~= false and attention_info.settings.notice_clbk then
					attention_info.settings.notice_clbk(data.unit, noticable)
				end
			end

			if attention_info.identified then
				delay = math_min(delay, attention_info.settings.verification_interval)
				attention_info.nearly_visible = nil
				local verified, vis_ray = nil
				local attention_pos = attention_info.handler:get_detection_m_pos()
				local dis = mvec3_dis(data.m_pos, attention_info.m_pos)

				if dis < my_data.detection.dis_max * 1.2 and (not attention_info.settings.max_range or dis < attention_info.settings.max_range * (attention_info.settings.detection and attention_info.settings.detection.range_mul or 1) * 1.2) then
					local detect_pos = nil

					if attention_info.is_husk_player and attention_info.unit:anim_data().crouch then
						detect_pos = tmp_vec1

						mvec3_set(detect_pos, attention_info.m_pos)
						mvec3_add(detect_pos, tweak_data.player.stances.default.crouched.head.translation)
					else
						detect_pos = attention_pos
					end

					local in_FOV = not attention_info.settings.notice_requires_FOV or data.enemy_slotmask and attention_info.unit:in_slot(data.enemy_slotmask)

					if not in_FOV then
						mvec3_dir(tmp_vec1, my_pos, attention_pos)

						my_head_fwd = my_head_fwd or data.unit:movement():m_head_rot():z()
						local angle = mvec3_angle(my_head_fwd, tmp_vec1)
						local angle_max = math_lerp(180, my_data.detection.angle_max, math_clamp((dis - 150) / 700, 0, 1))

						if angle_max > angle * 0.8 then
							in_FOV = true
						end						
					end

					if in_FOV then
						vis_ray = World:raycast("ray", my_pos, detect_pos, "slot_mask", data.visibility_slotmask, "ray_type", "ai_vision")

						if not vis_ray or vis_ray.unit:key() == u_key then
							verified = true
						end
					end
				end

				attention_info.verified = verified
				attention_info.dis = dis
				attention_info.vis_ray = vis_ray and vis_ray.dis or nil
				local is_ignored = false

				if attention_info.unit:movement() and attention_info.unit:movement().is_cuffed then
					is_ignored = attention_info.unit:movement():is_cuffed()
				end

				if is_ignored then
					CopLogicBase._destroy_detected_attention_object_data(data, attention_info)
				elseif verified then
					attention_info.release_t = nil
					attention_info.verified_t = t

					mvec3_set(attention_info.verified_pos, attention_pos)

					attention_info.last_verified_pos = mvec3_cpy(attention_pos)
					attention_info.verified_dis = dis
				elseif data.enemy_slotmask and attention_info.unit:in_slot(data.enemy_slotmask) then
					if attention_info.criminal_record and react_combat <= attention_info.settings.reaction then
						if not is_detection_persistent and mvec3_dis(attention_pos, attention_info.criminal_record.pos) > 700 then
							CopLogicBase._destroy_detected_attention_object_data(data, attention_info)
						else
							delay = math_min(0.2, delay)
							attention_info.verified_pos = mvec3_cpy(attention_info.criminal_record.pos)
							attention_info.verified_dis = dis

							if vis_ray and data.logic._chk_nearly_visible_chk_needed(data, attention_info, u_key) then
								local near_pos = tmp_vec1

								if attention_info.verified_dis < 2000 and math_abs(attention_pos.z - my_pos.z) < 300 then
									mvec3_set(near_pos, attention_pos)
									mvec3_set_z(near_pos, near_pos.z + 100)

									local near_vis_ray = World:raycast("ray", my_pos, near_pos, "slot_mask", data.visibility_slotmask, "ray_type", "ai_vision", "report")

									if near_vis_ray then
										local side_vec = tmp_vec1

										mvec3_set(side_vec, attention_pos)
										mvec3_sub(side_vec, my_pos)
										mvec3_cross(side_vec, side_vec, math_up)
										mvec3_set_length(side_vec, 150)
										mvec3_set(near_pos, attention_pos)
										mvec3_add(near_pos, side_vec)

										local near_vis_ray = World:raycast("ray", my_pos, near_pos, "slot_mask", data.visibility_slotmask, "ray_type", "ai_vision", "report")

										if near_vis_ray then
											mvec3_multiply(side_vec, -2)
											mvec3_add(near_pos, side_vec)

											near_vis_ray = World:raycast("ray", my_pos, near_pos, "slot_mask", data.visibility_slotmask, "ray_type", "ai_vision", "report")
										end
									end

									if not near_vis_ray then
										attention_info.nearly_visible = true
										attention_info.last_verified_pos = mvec3_cpy(near_pos)
									end
								end
							end
						end
					elseif attention_info.release_t and attention_info.release_t < t then
						CopLogicBase._destroy_detected_attention_object_data(data, attention_info)
					else
						attention_info.release_t = attention_info.release_t or t + attention_info.settings.release_delay
					end
				elseif attention_info.release_t and attention_info.release_t < t then
					CopLogicBase._destroy_detected_attention_object_data(data, attention_info)
				else
					attention_info.release_t = attention_info.release_t or t + attention_info.settings.release_delay
				end
			end
		end

		if player_importance_wgt and attention_info.is_human_player then
			local weight = mvec3_dir(tmp_vec1, attention_info.m_head_pos, my_pos)
			local e_fwd = nil

			if attention_info.is_husk_player then
				e_fwd = attention_info.unit:movement():detect_look_dir()
			else
				e_fwd = attention_info.unit:movement():m_head_rot():y()
			end

			local dot = mvec3_dot(e_fwd, tmp_vec1)
			weight = weight * weight * (1 - dot)

			player_importance_wgt[#player_importance_wgt + 1] = attention_info.u_key
			player_importance_wgt[#player_importance_wgt + 1] = weight
		end
	end

	if player_importance_wgt then
		managers.groupai:state():set_importance_weight(data.key, player_importance_wgt)
	end

	return delay
end
