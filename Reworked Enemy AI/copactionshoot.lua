local math_abs = math.abs
local math_lerp = math.lerp
local math_min = math.min
local math_round = math.round
local math_up = math.UP

local mvec3_cpy = mvector3.copy
local mvec3_set = mvector3.set
local mvec3_set_z = mvector3.set_z
local mvec3_norm = mvector3.normalize
local mvec3_dir = mvector3.direction
local mvec3_dis = mvector3.distance
local mvec3_set_l = mvector3.set_length
local mvec3_add = mvector3.add
local mvec3_dot = mvector3.dot
local mvec3_rand_orth = mvector3.random_orthogonal
local temp_vec2 = Vector3()

-- Fix an enemy turning condition only working for clients
-- From Streamlined Heisting
function CopActionShoot:update(t)
	local vis_state = self._ext_base:lod_stage()
	vis_state = vis_state or 4

	if vis_state == 1 then
		-- Nothing
	elseif self._skipped_frames < vis_state * 3 then
		self._skipped_frames = self._skipped_frames + 1

		return
	else
		self._skipped_frames = 1
	end

	local shoot_from_pos = self._shoot_from_pos
	local ext_anim = self._ext_anim
	local common_data = self._common_data
	local target_vec, target_dis, autotarget, target_pos = nil
	local attention = self._attention

	if attention then
		target_pos, target_vec, target_dis, autotarget = self:_get_target_pos(shoot_from_pos, attention, t)
		local tar_vec_flat = temp_vec2

		mvec3_set(tar_vec_flat, target_vec)
		mvec3_set_z(tar_vec_flat, 0)
		mvec3_norm(tar_vec_flat)

		local fwd = common_data.fwd
		local fwd_dot = mvec3_dot(fwd, tar_vec_flat)
		local active_actions = common_data.active_actions
		local queued_actions = common_data.queued_actions

		if (not active_actions[2] or active_actions[2]:type() == "idle") and (not queued_actions or not queued_actions[1] and not queued_actions[2]) and not self._ext_movement:chk_action_forbidden("walk") then
			local spin = tar_vec_flat:to_polar_with_reference(fwd, math_up).spin
			if math_abs(spin) > 25 then
				local new_action_data = {
					body_part = 2,
					type = "turn",
					angle = spin
				}

				self._ext_movement:action_request(new_action_data)
			end
		end

		target_vec = self:_upd_ik(target_vec, fwd_dot, t)
	end

	if not ext_anim.reload and not ext_anim.equip and not ext_anim.melee then
		local autofiring = self._autofiring
		if self._weapon_base:clip_empty() then
			if autofiring then
				self._weapon_base:stop_autofire()
				self._ext_movement:play_redirect("up_idle")

				self._autofiring = nil
				self._autoshots_fired = nil
			end

			if not ext_anim.base_no_reload then
				local res = CopActionReload._play_reload(self)

				if res then
					self._machine:set_speed(res, self._reload_speed)
				end

				if Network:is_server() then
					managers.network:session():send_to_peers("reload_weapon_cop", self._unit)
				end
			end
		elseif autofiring then
			if not target_vec or not common_data.allow_fire then
				self._weapon_base:stop_autofire()

				self._shoot_t = t + 0.6
				self._autofiring = nil
				self._autoshots_fired = nil

				self._ext_movement:play_redirect("up_idle")
			else
				local spread = self._spread
				local falloff, i_range = self:_get_shoot_falloff(target_dis, self._falloff)
				local dmg_buff = self._unit:base():get_total_buff("base_damage")
				local dmg_mul = (1 + dmg_buff) * falloff.dmg_mul
				local new_target_pos = self._shoot_history and self:_get_unit_shoot_pos(t, target_pos, target_dis, self._w_usage_tweak, falloff, i_range, autotarget)

				if new_target_pos then
					target_pos = new_target_pos
				else
					spread = math_min(20, spread)
				end

				local spread_pos = temp_vec2

				mvec3_rand_orth(spread_pos, target_vec)
				mvec3_set_l(spread_pos, spread)
				mvec3_add(spread_pos, target_pos)

				target_dis = mvec3_dir(target_vec, shoot_from_pos, spread_pos)
				local fired = self._weapon_base:trigger_held(shoot_from_pos, target_vec, dmg_mul, self._shooting_player, nil, nil, nil, attention.unit)

				if fired then
					if fired.hit_enemy and fired.hit_enemy.type == "death" and self._unit:unit_data().mission_element then
						self._unit:unit_data().mission_element:event("killshot", self._unit)
					end

					if not ext_anim.recoil and vis_state == 1 and not ext_anim.base_no_recoil and not ext_anim.move then
						self._ext_movement:play_redirect("recoil_auto")
					end

					if not autofiring or self._autoshots_fired >= autofiring - 1 then
						self._autofiring = nil
						self._autoshots_fired = nil

						self._weapon_base:stop_autofire()
						self._ext_movement:play_redirect("up_idle")

						if vis_state == 1 then
							self._shoot_t = t + (common_data.is_suppressed and 1.5 or 1) * math_lerp(falloff.recoil[1], falloff.recoil[2], self:_pseudorandom())
						else
							self._shoot_t = t + falloff.recoil[2]
						end
					else
						self._autoshots_fired = self._autoshots_fired + 1
					end
				end
			end
		elseif target_vec and common_data.allow_fire and self._shoot_t < t and self._mod_enable_t < t then
			local shoot = nil

			if autotarget or self._shooting_husk_player and self._next_vis_ray_t < t then
				if self._shooting_husk_player then
					self._next_vis_ray_t = t + 2
				end

				local fire_line = World:raycast("ray", shoot_from_pos, target_pos, "slot_mask", self._verif_slotmask, "ray_type", "ai_vision")

				if fire_line then
					if t - self._line_of_sight_t > 3 then
						local aim_delay_minmax = self._w_usage_tweak.aim_delay
						local lerp_dis = math_min(1, target_vec:length() / self._falloff[#self._falloff].r)
						local aim_delay = math_lerp(aim_delay_minmax[1], aim_delay_minmax[2], lerp_dis)
						aim_delay = aim_delay + self:_pseudorandom() * aim_delay * 0.3

						if common_data.is_suppressed then
							aim_delay = aim_delay * 1.5
						end

						self._shoot_t = t + aim_delay
					elseif fire_line.distance > 300 then
						shoot = true
					end
				else
					if t - self._line_of_sight_t > 1 and not self._last_vis_check_status then
						local shoot_hist = self._shoot_history
						local displacement = mvec3_dis(target_pos, shoot_hist.m_last_pos)
						local focus_delay = self._w_usage_tweak.focus_delay * math_min(1, displacement / self._w_usage_tweak.focus_dis)
						shoot_hist.focus_start_t = t
						shoot_hist.focus_delay = focus_delay
						shoot_hist.m_last_pos = mvec3_cpy(target_pos)
					end

					self._line_of_sight_t = t
					shoot = true
				end

				self._last_vis_check_status = shoot
			elseif self._shooting_husk_player then
				shoot = self._last_vis_check_status
			else
				shoot = true
			end

			if common_data.char_tweak.no_move_and_shoot and common_data.ext_anim and common_data.ext_anim.move then
				shoot = false
				self._shoot_t = t + (common_data.char_tweak.move_and_shoot_cooldown or 1)
			end

			if shoot then
				local melee = nil

				if autotarget and (not common_data.melee_countered_t or t - common_data.melee_countered_t > 15) and target_dis < 130 and self._w_usage_tweak.melee_speed and self._melee_timeout_t < t then
					melee = self:_chk_start_melee(target_vec, target_dis, autotarget, target_pos)
				end

				if not melee then
					local falloff, i_range = self:_get_shoot_falloff(target_dis, self._falloff)
					local dmg_buff = self._unit:base():get_total_buff("base_damage")
					local dmg_mul = (1 + dmg_buff) * falloff.dmg_mul
					local firemode = nil

					if self._automatic_weap then
						firemode = falloff.mode and falloff.mode[1] or 1
						local random_mode = self:_pseudorandom()

						for i_mode, mode_chance in ipairs(falloff.mode) do
							if random_mode <= mode_chance then
								firemode = i_mode

								break
							end
						end
					else
						firemode = 1
					end

					if firemode > 1 then
						self._weapon_base:start_autofire(firemode < 4 and firemode)

						if self._w_usage_tweak.autofire_rounds then
							if firemode < 4 then
								self._autofiring = firemode
							elseif falloff.autofire_rounds then
								local diff = falloff.autofire_rounds[2] - falloff.autofire_rounds[1]
								self._autofiring = math_round(falloff.autofire_rounds[1] + self:_pseudorandom() * diff)
							else
								local diff = self._w_usage_tweak.autofire_rounds[2] - self._w_usage_tweak.autofire_rounds[1]
								self._autofiring = math_round(self._w_usage_tweak.autofire_rounds[1] + self:_pseudorandom() * diff)
							end
						else
							Application:stack_dump_error("autofire_rounds is missing from weapon usage tweak data!", self._weap_tweak.usage)
						end

						self._autoshots_fired = 0

						if vis_state == 1 and not ext_anim.base_no_recoil and not ext_anim.move then
							self._ext_movement:play_redirect("recoil_auto")
						end
					else
						local spread = self._spread

						if autotarget then
							local new_target_pos = self._shoot_history and self:_get_unit_shoot_pos(t, target_pos, target_dis, self._w_usage_tweak, falloff, i_range, autotarget)

							if new_target_pos then
								target_pos = new_target_pos
							else
								spread = math_min(20, spread)
							end
						end

						local spread_pos = temp_vec2

						mvec3_rand_orth(spread_pos, target_vec)
						mvec3_set_l(spread_pos, spread)
						mvec3_add(spread_pos, target_pos)

						target_dis = mvec3_dir(target_vec, shoot_from_pos, spread_pos)
						local fired = self._weapon_base:singleshot(shoot_from_pos, target_vec, dmg_mul, self._shooting_player, nil, nil, nil, attention.unit)

						if fired and fired.hit_enemy and fired.hit_enemy.type == "death" and self._unit:unit_data().mission_element then
							self._unit:unit_data().mission_element:event("killshot", self._unit)
						end

						if vis_state == 1 then
							if not ext_anim.base_no_recoil and not ext_anim.move then
								self._ext_movement:play_redirect("recoil_single")
							end

							self._shoot_t = t + (common_data.is_suppressed and 1.5 or 1) * math_lerp(falloff.recoil[1], falloff.recoil[2], self:_pseudorandom())
						else
							self._shoot_t = t + falloff.recoil[2]
						end
					end
				end
			end
		end
	end

	if ext_anim.base_need_upd then
		self._ext_movement:upd_m_head_pos()
	end
end