local idstr_base = Idstring("base")

local math_abs = math.abs
local math_floor = math.floor
local math_random = math.random
local math_randomseed = math.randomseed
local math_round = math.round

local mvec3_cpy = mvector3.copy
local mvec3_dot = mvector3.dot
local mvec3_dis_sq = mvector3.distance_sq

local pairs_g = pairs

function CopActionHurt:init(action_desc, common_data)
	self._common_data = common_data
	self._ext_movement = common_data.ext_movement
	self._ext_inventory = common_data.ext_inventory
	self._ext_anim = common_data.ext_anim
	self._body_part = action_desc.body_part
	self._unit = common_data.unit
	self._machine = common_data.machine
	self._attention = common_data.attention
	self._action_desc = action_desc
	local t = TimerManager:game():time()
	local tweak_table = self._unit:base()._tweak_table
	local is_civilian = CopDamage.is_civilian(tweak_table)
	local is_female = self._machine:get_global("female") == 1
	local crouching = self._unit:anim_data().crouch or self._unit:anim_data().hurt and self._machine:get_parameter(self._machine:segment_state(Idstring("base")), "crh") > 0
	local redir_res = nil
	local action_type = action_desc.hurt_type

	if action_type == "knock_down" then
		action_type = "heavy_hurt"
	end

	if action_type == "fatal" then
		redir_res = self._ext_movement:play_redirect("fatal")

		if not redir_res then
			return
		end

		managers.hud:set_mugshot_downed(self._unit:unit_data().mugshot_id)
	elseif action_desc.variant == "tase" then
		redir_res = self._ext_movement:play_redirect("tased")

		if not redir_res then
			return
		end

		managers.hud:set_mugshot_tased(self._unit:unit_data().mugshot_id)
	elseif action_type == "fire_hurt" or action_type == "light_hurt" and action_desc.variant == "fire" then
		local char_tweak = tweak_data.character[self._unit:base()._tweak_table]
		local use_animation_on_fire_damage = nil

		if char_tweak.use_animation_on_fire_damage == nil then
			use_animation_on_fire_damage = true
		else
			use_animation_on_fire_damage = char_tweak.use_animation_on_fire_damage
		end

		if action_desc.fire_dot_data and action_desc.fire_dot_data.start_dot_dance_antimation then
			managers.fire:cop_hurt_fire_prediction(self._unit)

			if action_desc.ignite_character == "dragonsbreath" then
				self:_dragons_breath_sparks()
			end

			if self._unit:character_damage() ~= nil and self._unit:character_damage().get_last_time_unit_got_fire_damage ~= nil then
				local last_fire_recieved = self._unit:character_damage():get_last_time_unit_got_fire_damage()

				if last_fire_recieved == nil or t - last_fire_recieved > 1 then
					if use_animation_on_fire_damage then
						redir_res = self._ext_movement:play_redirect("fire_hurt")
						local dir_str = nil
						local fwd_dot = action_desc.direction_vec:dot(common_data.fwd)

						if fwd_dot < 0 then
							local hit_pos = action_desc.hit_pos
							local hit_vec = (hit_pos - common_data.pos):with_z(0):normalized()

							if mvec3_dot(hit_vec, common_data.right) > 0 then
								dir_str = "r"
							else
								dir_str = "l"
							end
						else
							dir_str = "bwd"
						end

						self._machine:set_parameter(redir_res, dir_str, 1)
					end

					self._unit:character_damage():set_last_time_unit_got_fire_damage(t)
				end
			end
		end
	elseif action_type == "taser_tased" then
		if self._unit:brain() and self._unit:brain()._current_logic_name ~= "intimidated" then
			local tase_data = tweak_data.tase_data[action_desc.variant] or tweak_data.tase_data.light

			if tase_data.duration then
				redir_res = self._ext_movement:play_redirect("explosion_tased")

				if not redir_res then
					return
				end

				if self._machine:get_global("shield") == 1 then -- check this instead of tweak table
					self._machine:set_parameter(redir_res, "shield_var" .. self:_pseudorandom(4), 1) -- concatenation is valid for numbers
				else
					self._machine:set_parameter(redir_res, "var" .. self:_pseudorandom(5), 1) -- concatenation is valid for numbers
				end
			else
				redir_res = self._ext_movement:play_redirect("taser")

				if not redir_res then
					return
				end

				self._machine:set_parameter(redir_res, "var" .. self:_pseudorandom(4), 1)
			end
		end
	elseif action_type == "light_hurt" then
		if not self._ext_anim.upper_body_active or self._ext_anim.upper_body_empty or self._ext_anim.recoil then
			redir_res = self._ext_movement:play_redirect(action_type)

			if not redir_res then
				return
			end

			local dir_str = nil
			local hit_pos = action_desc.hit_pos
			local fwd_dot = action_desc.direction_vec:dot(common_data.fwd)

			if fwd_dot < 0 then
				local hit_vec = (hit_pos - common_data.pos):with_z(0):normalized()

				if mvec3_dot(hit_vec, common_data.right) > 0 then
					dir_str = "r"
				else
					dir_str = "l"
				end
			else
				dir_str = "bwd"
			end

			self._machine:set_parameter(redir_res, dir_str, 1)
			self._machine:set_parameter(redir_res, self._ext_movement:m_com().z < hit_pos.z and "high" or "low", 1)
		end

		self._expired = true

		return true
	elseif action_type == "concussion" then
		redir_res = self._ext_movement:play_redirect("concussion_stun")

		if not redir_res then -- missing this for whatever reason
			return
		end

		if self._machine:get_global("shield") == 1 then
			self._machine:set_parameter(redir_res, "shield_var" .. self:_pseudorandom(4), 1) -- shields do have unique animations for this, but they're not going to be used as they look like shit without an idle redirect and clients won't necessarily be using REAI
		else
			self._machine:set_parameter(redir_res, "var" .. self:_pseudorandom(9), 1) -- concatenation is valid for numbers
		end
		
		self._sick_time = t + 3
	elseif action_type == "hurt_sick" then
		local ecm_hurts_table = self._common_data.char_tweak.ecm_hurts

		if not ecm_hurts_table then
			return
		end

		redir_res = self._ext_movement:play_redirect("hurt_sick")

		if not redir_res then
			return
		end

		local sick_variants = {}
		for i in pairs_g(ecm_hurts_table) do
			sick_variants[#sick_variants + 1] = i
		end

		local variant = sick_variants[self:_pseudorandom(#sick_variants)]
		local ecm_variant = ecm_hurts_table[variant]
		local ecm_variant_min_duration = ecm_variant.min_duration
		local duration = ecm_variant_min_duration + (ecm_variant.max_duration - ecm_variant_min_duration) * self:_pseudorandom()

		for i = 1, #sick_variants do
			local hurt_sick = sick_variants[i]
			self._machine:set_global(hurt_sick, hurt_sick == variant and 1 or 0)
		end

		self._sick_time = t + duration
	elseif action_type == "poison_hurt" then
		redir_res = self._ext_movement:play_redirect("hurt_poison")

		if not redir_res then
			return
		end

		self._sick_time = t + 2
	elseif action_type == "bleedout" then
		redir_res = self._ext_movement:play_redirect("bleedout")

		if not redir_res then
			return
		end
	elseif action_type == "death" and action_desc.variant == "fire" then
		local variant = 1
		local variant_count = #CopActionHurt.fire_death_anim_variants_length or 5

		if variant_count > 1 then
			variant = self:_pseudorandom(variant_count)
		end

		if not self._ext_movement:died_on_rope() then
			self:_prepare_ragdoll()

			redir_res = self._ext_movement:play_redirect("death_" .. alive(action_desc.weapon_unit) and (tweak_data.weapon[action_desc.weapon_unit:base():get_name_id()] or tweak_data.weapon.amcar).fire_variant or "fire")

			if not redir_res then
				return
			end

			for i = 1, variant_count do
				self._machine:set_parameter(redir_res, "var" .. i, i == variant and 1 or 0) -- concatenation is valid for numbers
			end
		else
			self:force_ragdoll()
		end

		self:_start_enemy_fire_effect_on_death(variant, action_desc)
		managers.fire:check_achievemnts(self._unit, t)
	elseif action_type == "death" and action_desc.variant == "poison" then
		self:force_ragdoll()
	elseif action_type == "death" and (self._ext_anim.run and self._ext_anim.move_fwd or self._ext_anim.sprint) and not common_data.char_tweak.no_run_death_anim then
		self:_prepare_ragdoll()

		redir_res = self._ext_movement:play_redirect("death_run")

		if not redir_res then
			return
		end

		local variant = self.running_death_anim_variants[is_female and "female" or "male"] or 1

		if variant > 1 then
			variant = self:_pseudorandom(variant)
		end

		self._machine:set_parameter(redir_res, "var" .. variant, 1) -- concatenation is valid for numbers
	elseif action_type == "death" and (self._ext_anim.run or self._ext_anim.ragdoll) and self:_start_ragdoll() then
		self.update = self._upd_ragdolled
	elseif action_type == "heavy_hurt" and (self._ext_anim.run or self._ext_anim.sprint) and not common_data.is_suppressed and not crouching then
		redir_res = self._ext_movement:play_redirect("heavy_run")

		if not redir_res then
			return
		end

		local variant = self.running_hurt_anim_variants.fwd or 1

		if variant > 1 then
			variant = self:_pseudorandom(variant)
		end

		self._machine:set_parameter(redir_res, "var" .. variant, 1) -- concatenation is valid for numbers
	else
		local variant, old_variant, old_info = nil

		if (action_type == "hurt" or action_type == "heavy_hurt") and self._ext_anim.hurt then
			for i = 1, self.hurt_anim_variants_highest_num do
				if self._machine:get_parameter(self._machine:segment_state(Idstring("base")), "var" .. i) then
					old_variant = i

					break
				end
			end

			if old_variant ~= nil then
				old_info = {
					fwd = self._machine:get_parameter(self._machine:segment_state(Idstring("base")), "fwd"),
					bwd = self._machine:get_parameter(self._machine:segment_state(Idstring("base")), "bwd"),
					l = self._machine:get_parameter(self._machine:segment_state(Idstring("base")), "l"),
					r = self._machine:get_parameter(self._machine:segment_state(Idstring("base")), "r"),
					high = self._machine:get_parameter(self._machine:segment_state(Idstring("base")), "high"),
					low = self._machine:get_parameter(self._machine:segment_state(Idstring("base")), "low"),
					crh = self._machine:get_parameter(self._machine:segment_state(Idstring("base")), "crh"),
					mod = self._machine:get_parameter(self._machine:segment_state(Idstring("base")), "mod"),
					hvy = self._machine:get_parameter(self._machine:segment_state(Idstring("base")), "hvy")
				}
			end
		end

		local redirect = action_type

		if action_type == "shield_knock" then
			redirect = "shield_knock_var" .. self:_pseudorandom(self.shield_knock_variants) - 1 -- var0-4
		end

		if redirect then
			redir_res = self._ext_movement:play_redirect(redirect)
		end

		if not redir_res then
			return
		end

		if action_desc.variant ~= "bleeding" then
			local nr_variants = self._ext_anim.base_nr_variants
			local death_type = nil
			local height = nil

			if nr_variants then
				variant = self:_pseudorandom(nr_variants)
			else
				local fwd_dot = action_desc.direction_vec:dot(common_data.fwd)
				local right_dot = action_desc.direction_vec:dot(common_data.right)
				local dir_str = nil

				if math_abs(right_dot) < math_abs(fwd_dot) then
					if fwd_dot < 0 then
						dir_str = "fwd"
					else
						dir_str = "bwd"
					end
				elseif right_dot > 0 then
					dir_str = "l"
				else
					dir_str = "r"
				end

				self._machine:set_parameter(redir_res, dir_str, 1)

				local hit_z = action_desc.hit_pos.z
				height = self._ext_movement:m_com().z < hit_z and "high" or "low"

				if action_type == "death" then
					if is_civilian then
						death_type = "normal"
					else
						death_type = action_desc.death_type
					end

					if is_female then
						variant = self.death_anim_fe_variants[death_type][crouching and "crouching" or "not_crouching"][dir_str][height]
					else
						variant = self.death_anim_variants[death_type][crouching and "crouching" or "not_crouching"][dir_str][height]
					end

					if variant > 1 then
						variant = self:_pseudorandom(variant)
					end

					self:_prepare_ragdoll()
				elseif action_type ~= "shield_knock" and action_type ~= "counter_tased" then
					if old_variant and (old_info[dir_str] == 1 and old_info[height] == 1 and old_info.mod == 1 and action_type == "hurt" or old_info.hvy == 1 and action_type == "heavy_hurt") then
						variant = old_variant
					end

					if not variant then
						if action_type == "expl_hurt" then
							variant = self.hurt_anim_variants[action_type][dir_str]
						else
							variant = self.hurt_anim_variants[action_type].not_crouching[dir_str][height]
						end

						if variant > 1 then
							variant = self:_pseudorandom(variant)
						end
					end
				end
			end

			variant = variant or 1

			self._machine:set_parameter(redir_res, "var" .. variant, 1) -- concatenation is valid for numbers

			if height then
				self._machine:set_parameter(redir_res, height, 1)
			end

			if crouching then
				self._machine:set_parameter(redir_res, "crh", 1)
			end

			if action_type == "hurt" then
				self._machine:set_parameter(redir_res, "mod", 1)
			elseif action_type == "heavy_hurt" then
				self._machine:set_parameter(redir_res, "hvy", 1)
			elseif action_type == "death" and (death_type or action_desc.death_type) == "heavy" and not is_civilian then
				self._machine:set_parameter(redir_res, "heavy", 1)
			elseif action_type == "expl_hurt" then
				self._machine:set_parameter(redir_res, "expl", 1)
			end
		end
	end

	if self._ext_anim.upper_body_active and not self._ragdolled then
		self._ext_movement:play_redirect("up_idle")
	end

	self._last_vel_z = 0
	self._hurt_type = action_type
	self._variant = action_desc.variant
	self._body_part = action_desc.body_part

	if action_type == "bleedout" then
		self.update = self._upd_bleedout
		self._shoot_t = t + 1

		if Network:is_server() then
			self._ext_inventory:equip_selection(1, true)
		end

		local weapon_unit = self._ext_inventory:equipped_unit()
		self._weapon_base = weapon_unit:base()
		local weap_tweak = weapon_unit:base():weapon_tweak_data()
		local weapon_usage_tweak = common_data.char_tweak.weapon[weap_tweak.usage]
		self._weapon_unit = weapon_unit
		self._weap_tweak = weap_tweak
		self._w_usage_tweak = weapon_usage_tweak
		self._reload_speed = weapon_usage_tweak.RELOAD_SPEED
		self._spread = weapon_usage_tweak.spread
		self._falloff = weapon_usage_tweak.FALLOFF
		self._head_modifier_name = Idstring("look_head")
		self._arm_modifier_name = Idstring("aim_r_arm")
		self._head_modifier = self._machine:get_modifier(self._head_modifier_name)
		self._arm_modifier = self._machine:get_modifier(self._arm_modifier_name)
		self._aim_vec = mvec3_cpy(common_data.fwd)
		self._anim = redir_res

		if not self._shoot_history then
			self._shoot_history = {
				focus_error_roll = self:_pseudorandom(360),
				focus_start_t = t,
				focus_delay = weapon_usage_tweak.focus_delay,
				m_last_pos = common_data.pos + common_data.fwd * 500
			}
		end
	elseif action_type == "hurt_sick" or action_type == "poison_hurt" or action_type == "concussion" then
		self.update = self._upd_sick
	elseif action_type == "taser_tased" then
		local tase_data = tweak_data.tase_data[action_desc.variant] or tweak_data.tase_data.light

		if tase_data.duration then
			self._tased_down_time = t + tase_data.duration
			self.update = self._upd_tased_down
		else
			self.update = self._upd_hurt
		end
	elseif action_desc.variant ~= "tase" and not self._ragdolled then
		if self._unit:anim_data().skip_force_to_graph then
			self.update = self._upd_empty
		else
			self.update = self._upd_hurt
		end
	end

	local shoot_chance = nil

	if self._ext_inventory and not self._weapon_dropped and not self._ext_movement:cool() and t - self._ext_movement:not_cool_t() > 3 then
		local weapon_unit = self._ext_inventory:equipped_unit()

		if weapon_unit then
			if action_type == "counter_tased" or action_type == "taser_tased" then
				weapon_unit:base():on_reload() -- ??

				shoot_chance = 1
			elseif action_type == "death" then
				if common_data.char_tweak.shooting_death then -- since this should only apply to dying
					shoot_chance = 0.1
				end
			elseif action_type == "hurt" or action_type == "heavy_hurt" then
				shoot_chance = 0.1
			end
		end
	end

	if shoot_chance then
		local equipped_weapon = self._ext_inventory:equipped_unit()
		local rand = self:_pseudorandom()

		if equipped_weapon and (not equipped_weapon:base().clip_empty or not equipped_weapon:base():clip_empty()) and rand <= shoot_chance then
			self._weapon_unit = equipped_weapon

			self._unit:movement():set_friendly_fire(true)

			self._friendly_fire = true

			if equipped_weapon:base():weapon_tweak_data().auto then
				equipped_weapon:base():start_autofire()

				self._shooting_hurt = true
			else
				self._delayed_shooting_hurt_clbk_id = "shooting_hurt" .. tostring(self._unit:key())

				managers.enemy:add_delayed_clbk(self._delayed_shooting_hurt_clbk_id, callback(self, self, "clbk_shooting_hurt"), TimerManager:game():time() + math.lerp(0.2, 0.4, self:_pseudorandom()))
			end
		end
	end

	if not self._unit:base().nick_name then
		if action_desc.variant == "fire" then
			if tweak_table ~= "tank" and tweak_table ~= "tank_hw" and self._machine:get_global("shield") ~= 1 then -- check this instead of tweak table
				local fire_variant = alive(action_desc.weapon_unit) and (tweak_data.weapon[action_desc.weapon_unit:base():get_name_id()] or tweak_data.weapon.amcar).fire_variant or "fire"

				if action_desc.hurt_type == "fire_hurt" and tweak_table ~= "spooc" then
					self._unit:sound():say(fire_variant == "money" and "moneythrower_hurt" or "burnhurt", nil, fire_variant == "money")
				elseif action_desc.hurt_type == "death" then
					self._unit:sound():say(fire_variant == "money" and "moneythrower_death" or "burndeath", nil, fire_variant == "money")
				end
			end
		elseif action_type == "death" then
			self._unit:sound():say("x02a_any_3p", true)
		elseif action_type == "counter_tased" or action_type == "taser_tased" then
			self._unit:sound():say("tasered")
		else
			self._unit:sound():say("x01a_any_3p", true)
		end

		if (tweak_table == "tank" or tweak_table == "tank_hw") and action_type == "death" then
			local unit_id = self._unit:id()

			managers.fire:remove_dead_dozer_from_overgrill(unit_id)
		end

		if Network:is_server() then
			local radius, filter_name = nil
			local default_radius = managers.groupai:state():whisper_mode() and tweak_data.upgrades.cop_hurt_alert_radius_whisper or tweak_data.upgrades.cop_hurt_alert_radius

			if action_desc.attacker_unit and alive(action_desc.attacker_unit) and action_desc.attacker_unit:base().upgrade_value then
				radius = action_desc.attacker_unit:base():upgrade_value("player", "silent_kill") or default_radius
			elseif action_desc.attacker_unit and alive(action_desc.attacker_unit) and action_desc.attacker_unit:base().is_local_player then
				radius = managers.player:upgrade_value("player", "silent_kill", default_radius)
			end

			local new_alert = {
				"vo_distress",
				common_data.ext_movement:m_head_pos(),
				radius or default_radius,
				self._unit:brain():SO_access(),
				self._unit
			}

			managers.groupai:state():propagate_alert(new_alert)
		end
	end

	if action_type == "death" or action_type == "bleedout" or action_desc.variant == "tased" or action_type == "fatal" then
		self._floor_normal = self:_get_floor_normal(common_data.pos, common_data.fwd, common_data.right)
	end

	CopActionAct._create_blocks_table(self, action_desc.blocks)
	self._ext_movement:enable_update()

	if (self._body_part == 1 or self._body_part == 2) and Network:is_server() then
		local stand_rsrv = self._unit:brain():get_pos_rsrv("stand")

		if not stand_rsrv or mvec3_dis_sq(stand_rsrv.position, common_data.pos) > 400 then
			self._unit:brain():add_pos_rsrv("stand", {
				radius = 30,
				position = mvec3_cpy(common_data.pos)
			})
		end
	end

	if self:is_network_allowed(action_desc) then
		self._common_data.ext_network:send("action_hurt_start", CopActionHurt.hurt_type_to_idx(action_desc.hurt_type), action_desc.body_part, CopActionHurt.death_type_to_idx(action_desc.death_type), CopActionHurt.type_to_idx(action_desc.type), CopActionHurt.variant_to_idx(action_desc.variant), action_desc.direction_vec or Vector3(), action_desc.hit_pos or Vector3())
	end

	return true
end

function CopActionHurt:_upd_sick(t)
	if not self._sick_time or self._sick_time < t then
		self._ext_movement:play_redirect("idle") -- so concussion animations don't look like shit after they end for shields, but they still remain unused
		self._expired = true
	end
end

function CopActionHurt:_pseudorandom(a, b) -- might be worth just nuking this since it's pretty malfunctional
	local t = math_floor((managers.game_play_central:get_heist_timer() + 60) * 10 + 0.5) / 10 -- TODO: THIS IS SHIT, FIX THIS! temp fixes the random results being shitty within 60(?)s of heist start and will at least be consistent with REAI peers
	local r = math_random() * 999 + 1

	math_randomseed(self._unit:id() ^ (t / 183.62) * 100 % 100000)

	local ret = a and b and math_random(a, b) or a and math_random(a) or math_random()

	math_randomseed(os.time() / r + Application:time())

	for i = 1, math_round(math_random() * 10) do
		math_random()
	end

	return ret
end