-- The first entry in the path should be our current position, if not then update it
-- If we deviate from our path, utilise m_host_stop_pos to return to where we deviated, which is set upon exiting the action and ensures we 
-- don't take an invalid path, if we can continue from where we deviated to and move to the next nav point just take the path
-- (no obstructions and height difference between current pos and next nav point pos doesn't exceed 1m)
-- We still will have to catch up with the host position however, but this should at least address some cases of cops taking invalid paths
-- This should be fine with unmodded players

-- Also fix clients waiting for _upd_wait_for_full_blend receiving navpoints that would go unaccounted for, haven't had this
-- occur in gameplay, but account for it anyway

-- And do some minor optimizations

local mrot_lookat = mrotation.set_look_at
local mrot_slerp = mrotation.slerp

local mvec3_cpy = mvector3.copy
local mvec3_cross = mvector3.cross
local mvec3_dis = mvector3.distance
local mvec3_dot = mvector3.dot
local mvec3_norm = mvector3.normalize
local mvec3_rot = mvector3.rotate_with
local mvec3_set = mvector3.set
local mvec3_set_z = mvector3.set_z
local mvec3_sub = mvector3.subtract

local math_abs = math.abs
local math_ceil = math.ceil
local math_min = math.min
local math_up = math.UP

local react_shoot = AIAttentionObject.REACT_SHOOT
local react_surprised = AIAttentionObject.REACT_SURPRISED

local table_insert = table.insert

local temp_rot1 = Rotation()

local tmp_vec1 = Vector3()
local tmp_vec2 = Vector3()
local tmp_vec3 = Vector3()

function CopActionWalk:_init()
	if not self:_sanitize() then
		return
	end

	self._init_called = true
	self._walk_velocity = self:_get_max_walk_speed()
	local action_desc = self._action_desc
	local common_data = self._common_data

	if _G.REAI.settings.masochism then
		common_data.char_tweak.no_run_start = true
		common_data.char_tweak.no_run_stop = true
	end

	if self._sync then
		if managers.groupai:state():all_AI_criminals()[common_data.unit:key()] then
			self._nav_link_invul = true
		end

		local old_path = self._nav_path
		local nav_path = {}

		for i = 1, #old_path do
			local nav_point = old_path[i]
			if nav_point.x then
				nav_path[#nav_path + 1] = nav_point
			elseif alive(nav_point) then -- navlink
				nav_path[#nav_path + 1] = {
					element = nav_point:script_data().element,
					c_class = nav_point
				}
			else
				return false
			end
		end

		self._nav_path = nav_path

		if action_desc.path_simplified and action_desc.persistent then
			local new_nav_points = self._simplified_path
	
			for i = 1, #new_nav_points do
				local nav_point = new_nav_points[i]
				nav_path[#nav_path + 1] = nav_point.x and mvec3_cpy(nav_point) or nav_point
			end

			self._simplified_path = nav_path
		elseif not managers.groupai:state():enemy_weapons_hot() then
			self._simplified_path = nav_path
		else
			self._simplified_path = self._calculate_simplified_path(mvec3_cpy(common_data.pos), nav_path, self._common_data.stance.name == "ntl" and 2 or 1, true, true)
		end
	else
		local nav_path = self._nav_path
		local new_nav_points = self._simplified_path -- Normally vanilla only accounts for new nav points received during _upd_wait_for_full_blend on the host
		
		if new_nav_points then
			for i = 1, #new_nav_points do
				local new_nav_point = new_nav_points[i]
				
				nav_path[#nav_path + 1] = new_nav_point
			end
		end

		if action_desc.interrupted then -- Action interrupted, we need to insert the current unit position		
			if not nav_path[2] then
				nav_path[2] = nav_path[1]
			end
		
			nav_path[1] = mvec3_cpy(common_data.pos) -- If moving from this position to the next would lead to an invalid path, we should use m_host_stop_pos to return to where we deviated to ensure a valid path
			-- After testing and drawing the vectors this is correct behaviour, good job overkill
		elseif not nav_path[2] or not nav_path[1].x or nav_path[1] ~= common_data.pos then -- Seemed to get crashes with nav_path[2] being nil, make sure the path is at least 2 entries and entry 1 is our position
			table_insert(nav_path, 1, mvec3_cpy(common_data.pos)) -- Insert our position as the first entry
		end

		for i = 1, #nav_path do
			local nav_point = nav_path[i]
			if not nav_point.x then
				function nav_point.element.value(element, name)
					return element[name]
				end

				function nav_point.element.nav_link_wants_align_pos(element)
					return element.from_idle
				end
			end
		end

		if not action_desc.host_stop_pos_ahead then
			local to_pos = self._nav_point_pos(nav_path[2])
			-- Still not verified whether it's necessary to account for height, do it just to be safe	
			if math_abs(common_data.pos.z - to_pos.z) > 100 or managers.navigation:raycast({tracker_from = common_data.nav_tracker, pos_to = to_pos}) then -- Moving from our position to the next navpoint would be invalid
				table_insert(nav_path, 2, mvec3_cpy(self._ext_movement:m_host_stop_pos())) -- insert m_host_stop_pos to return to where we deviated

				self._host_stop_pos_ahead = true
			end
		end
		
		self._nav_path = nav_path
		
		if action_desc.path_simplified and action_desc.persistent then
			self._simplified_path = nav_path
		elseif not managers.groupai:state():enemy_weapons_hot() then
			self._simplified_path = nav_path
		else
			local good_pos = mvec3_cpy(common_data.pos)
			self._simplified_path = self._calculate_simplified_path(good_pos, nav_path, 2, false, true)
		end
	end

	if not self._simplified_path[2].x then
		self._next_is_nav_link = self._simplified_path[2]
	end

	self._curve_path_index = 1

	self:_chk_start_anim(CopActionWalk._nav_point_pos(self._simplified_path[2]))

	if self._start_run then
		self:_set_updator("_upd_start_anim_first_frame")
	end

	if not self._start_run_turn and mvec3_dis(self._nav_point_pos(self._simplified_path[2]), self._simplified_path[1]) > 400 and self._ext_base:lod_stage() == 1 then
		self._curve_path = self:_calculate_curved_path(self._simplified_path, 1, 1)
	else
		self._curve_path = {
			self._simplified_path[1],
			mvec3_cpy(self._nav_point_pos(self._simplified_path[2]))
		}
	end

	if #self._simplified_path == 2 and not self._no_run_stop and not self._no_walk and self._haste ~= "walk" and mvec3_dis(self._curve_path[2], self._curve_path[1]) >= 120 then
		self._chk_stop_dis = 210
	end

	if self._sync then
		local sync_yaw = 0

		if self._end_rot then
			local yaw = self._end_rot:yaw()

			if yaw < 0 then
				yaw = 360 + yaw
			end

			sync_yaw = 1 + math_ceil(yaw * 254 / 360)
		end

		local sync_haste = self._haste == "walk" and 1 or 2
		local nav_link_act_index, nav_link_act_yaw = nil
		local next_nav_point = self._simplified_path[2]
		local nav_link_from_idle = false

		if next_nav_point.x then
			nav_link_act_index = 0
			nav_link_act_yaw = 1
		else
			nav_link_act_index = CopActionAct._get_act_index(CopActionAct, next_nav_point.element:value("so_action"))
			nav_link_act_yaw = next_nav_point.element:value("rotation")

			if nav_link_act_yaw < 0 then
				nav_link_act_yaw = 360 + nav_link_act_yaw
			end

			nav_link_act_yaw = math_ceil(255 * nav_link_act_yaw / 360)

			if nav_link_act_yaw == 0 then
				nav_link_act_yaw = 255
			end

			if next_nav_point.element:nav_link_wants_align_pos() then
				nav_link_from_idle = true
			else
				nav_link_from_idle = false
			end

			self._nav_link_synched_with_start = true
		end

		local pose_code = nil

		if not action_desc.pose then
			pose_code = 0
		elseif action_desc.pose == "stand" then
			pose_code = 1
		else
			pose_code = 2
		end

		local end_pose_code = nil

		if not action_desc.end_pose then
			end_pose_code = 0
		elseif action_desc.end_pose == "stand" then
			end_pose_code = 1
		else
			end_pose_code = 2
		end

		self._ext_network:send("action_walk_start", self._nav_point_pos(next_nav_point), nav_link_act_yaw, nav_link_act_index, nav_link_from_idle, sync_haste, sync_yaw, self._no_walk and true or false, self._no_strafe and true or false, pose_code, end_pose_code)
		
		self._unit:brain():rem_pos_rsrv("stand")
		self._unit:brain():add_pos_rsrv("move_dest", {
			radius = 30,
			position = mvec3_cpy(self._simplified_path[#self._simplified_path])
		})
	else
		local pose = action_desc.pose

		if pose and not self._unit:anim_data()[pose] then
			if pose == "stand" then
				local action, success = CopActionStand:new(action_desc, self._common_data)
			else
				local action, success = CopActionCrouch:new(action_desc, self._common_data)
			end
		end
	end

	return true
end

function CopActionWalk:update(t)
	if self._ik_update then
		self._ik_update(t)
	end

	local dt = nil
	local vis_state = self._ext_base:lod_stage()
	vis_state = vis_state or 4

	if vis_state == 1 then
		dt = t - self._last_upd_t
		self._last_upd_t = TimerManager:game():time()
	elseif self._skipped_frames < vis_state then
		self._skipped_frames = self._skipped_frames + 1

		return
	else
		self._skipped_frames = 1
		dt = t - self._last_upd_t
		self._last_upd_t = TimerManager:game():time()
	end

	local ext_anim = self._ext_anim

	if self._end_of_path and (not ext_anim.act or not ext_anim.walk) then
		if self._next_is_nav_link then
			self:_set_updator("_upd_nav_link_first_frame")
			self:update(t)

			return
		elseif self._persistent then
			self:_set_updator("_upd_wait")
		else
			self._expired = true

			if self._end_rot then
				self._ext_movement:set_rotation(self._end_rot)
			end
		end
	else
		self:_nav_chk_walk(t, dt, vis_state)
	end

	local move_dir = tmp_vec3

	mvec3_set(move_dir, self._last_pos)
	mvec3_sub(move_dir, self._common_data.pos)
	mvec3_set_z(move_dir, 0)

	if self._cur_vel < 0.1 or ext_anim.act and ext_anim.walk then
		move_dir = nil
	end

	local anim_data = ext_anim

	if move_dir and not self._expired then
		local face_fwd = tmp_vec1
		local wanted_walk_dir = nil
		local move_dir_norm = move_dir:normalized()

		if self._no_strafe or self._walk_turn then
			wanted_walk_dir = "fwd"
		else
			if self._curve_path_end_rot and mvector3.distance_sq(self._last_pos, self._footstep_pos) < 19600 then
				mvec3_set(face_fwd, self._common_data.fwd)
			elseif self._attention_pos then
				mvec3_set(face_fwd, self._attention_pos)
				mvec3_sub(face_fwd, self._common_data.pos)
			elseif self._footstep_pos then
				mvec3_set(face_fwd, self._footstep_pos)
				mvec3_sub(face_fwd, self._common_data.pos)
			else
				mvec3_set(face_fwd, self._common_data.fwd)
			end

			mvec3_set_z(face_fwd, 0)
			mvec3_norm(face_fwd)

			local face_right = tmp_vec2

			mvec3_cross(face_right, face_fwd, math_up)
			mvec3_norm(face_right)

			local right_dot = mvec3_dot(move_dir_norm, face_right)
			local fwd_dot = mvec3_dot(move_dir_norm, face_fwd)

			if math_abs(right_dot) < math_abs(fwd_dot) then
				if (anim_data.move_l and right_dot < 0 or anim_data.move_r and right_dot > 0) and math_abs(fwd_dot) < 0.73 then
					wanted_walk_dir = anim_data.move_side
				elseif fwd_dot > 0 then
					wanted_walk_dir = "fwd"
				else
					wanted_walk_dir = "bwd"
				end
			elseif (anim_data.move_fwd and fwd_dot > 0 or anim_data.move_bwd and fwd_dot < 0) and math_abs(right_dot) < 0.73 then
				wanted_walk_dir = anim_data.move_side
			elseif right_dot > 0 then
				wanted_walk_dir = "r"
			else
				wanted_walk_dir = "l"
			end
		end

		local rot_new = nil

		if self._curve_path_end_rot then
			local dis_lerp = 1 - math_min(1, mvec3_dis(self._last_pos, self._footstep_pos) / 140)
			rot_new = temp_rot1

			mrot_slerp(rot_new, self._curve_path_end_rot, self._nav_link_rot or self._end_rot, dis_lerp)
		else
			local wanted_u_fwd = tmp_vec1

			mvec3_set(wanted_u_fwd, move_dir_norm)
			mvec3_rot(wanted_u_fwd, self._walk_side_rot[wanted_walk_dir])
			mrot_lookat(temp_rot1, wanted_u_fwd, math_up)

			rot_new = temp_rot1

			mrot_slerp(rot_new, self._common_data.rot, rot_new, math_min(1, dt * 5))
		end

		self._ext_movement:set_rotation(rot_new)

		if self._chk_stop_dis and not self._common_data.char_tweak.no_run_stop then
			local end_dis = mvec3_dis(self._nav_point_pos(self._simplified_path[#self._simplified_path]), self._last_pos)

			if end_dis < self._chk_stop_dis then
				local stop_anim_fwd = not self._nav_link_rot and self._end_rot and self._end_rot:y() or move_dir_norm:rotate_with(self._walk_side_rot[wanted_walk_dir])
				local fwd_dot = mvec3_dot(stop_anim_fwd, move_dir_norm)
				local move_dir_r_norm = tmp_vec3

				mvec3_cross(move_dir_r_norm, move_dir_norm, math_up)

				local fwd_dot = mvec3_dot(stop_anim_fwd, move_dir_norm)
				local r_dot = mvec3_dot(stop_anim_fwd, move_dir_r_norm)
				local stop_anim_side = nil

				if math_abs(r_dot) < math_abs(fwd_dot) then
					if fwd_dot > 0 then
						stop_anim_side = "fwd"
					else
						stop_anim_side = "bwd"
					end
				elseif r_dot > 0 then
					stop_anim_side = "l"
				else
					stop_anim_side = "r"
				end

				local stop_pose = nil

				if self._action_desc.end_pose then
					stop_pose = self._action_desc.end_pose
				else
					stop_pose = ext_anim.pose
				end

				if stop_pose ~= ext_anim.pose then
					local pose_redir_res = self._ext_movement:play_redirect(stop_pose)

					if not pose_redir_res then
						debug_pause_unit(self._unit, "STOP POSE FAIL!!!", self._unit, stop_pose)
					end
				end

				local stop_dis = self._anim_movement[stop_pose]["run_stop_" .. stop_anim_side]

				if stop_dis and end_dis < stop_dis then
					self._stop_anim_side = stop_anim_side
					self._stop_anim_fwd = stop_anim_fwd
					self._stop_dis = stop_dis

					self:_set_updator("_upd_stop_anim_first_frame")
				end
			end
		elseif self._walk_turn and not self._chk_stop_dis then
			local end_dis = mvec3_dis(self._curve_path[self._curve_path_index + 1], self._last_pos)

			if end_dis < 45 then
				self:_set_updator("_upd_walk_turn_first_frame")
			end
		end

		local stance = self._stance.name
		local pose = self._stance.values[4] > 0 and "wounded" or ext_anim.pose or "stand"
		local walk_anim_velocities = self._walk_anim_velocities
		local pose_velocities = walk_anim_velocities[pose] or walk_anim_velocities["stand"] or walk_anim_velocities["crouch"]
		pose_velocities = pose_velocities[stance_name] or pose_velocities["cbt"] or pose_velocities["hos"] or pose_velocities["ntl"]	
		local real_velocity = self._cur_vel
		local variant = self._haste

		if variant == "run" then
			if ext_anim.sprint then
				if real_velocity > 480 and ext_anim.pose == "stand" then
					variant = "sprint"
				elseif real_velocity > 250 then
					variant = "run"
				elseif not self._no_walk then
					variant = "walk"
				end
			elseif ext_anim.run then
				if real_velocity > 530 and pose_velocities and pose_velocities.sprint and ext_anim.pose == "stand" then
					variant = "sprint"
				elseif real_velocity > 250 then
					variant = "run"
				elseif not self._no_walk then
					variant = "walk"
				end
			elseif real_velocity > 530 and pose_velocities and pose_velocities.sprint and ext_anim.pose == "stand" then
				variant = "sprint"
			elseif real_velocity > 300 then
				variant = "run"
			elseif not self._no_walk then
				variant = "walk"
			end
		end

		self:_adjust_move_anim(wanted_walk_dir, variant)

		local anim_walk_speed = self._walk_anim_velocities[pose][self._stance.name][variant][wanted_walk_dir]
		local wanted_walk_anim_speed = real_velocity / anim_walk_speed

		self:_adjust_walk_anim_speed(dt, wanted_walk_anim_speed)
	end

	self:_set_new_pos(dt)
end

-- Don't turn to face attentions unless it's a shoot reaction
function CopActionWalk:on_attention(attention)
	if attention then
		self._attention = attention

		if attention.handler then
			if (managers.groupai:state():enemy_weapons_hot() and react_shoot or react_surprised) <= attention.reaction then
				self._attention_pos = attention.handler:get_attention_m_pos()
			else
				self._attention_pos = nil
			end
		elseif self._common_data.stance.name ~= "ntl" then
			if attention.unit then
				self._attention_pos = attention.unit:movement():m_pos()
			else
				self._attention_pos = nil
			end
		end
	else
		self._attention_pos = nil
	end
end

-- Apparently this got reworked at some point for the worse?
function CopActionWalk._calculate_simplified_path(good_pos, original_path, nr_iterations, is_host, apply_padding)
	local simplified_path = {good_pos}
	local size = #original_path

	if size > 2 then
		local from = 1	
		while from < size do
			local to = from + 2
			while to <= size do
				local pos_mid = original_path[to - 1]
				if pos_mid.x then
					local pos_from = original_path[from]
					local pos_to = CopActionWalk._nav_point_pos(original_path[to])
					local add_point = math_abs(pos_from.z - pos_mid.z - (pos_mid.z - pos_to.z)) > 60 or CopActionWalk._chk_shortcut_pos_to_pos(pos_from, pos_to)

					if add_point then
						simplified_path[#simplified_path + 1] = mvec3_cpy(pos_mid)
						from = to - 1
						break
					end
				else
					simplified_path[#simplified_path + 1] = pos_mid -- Navlink
					if original_path[to].x then
						simplified_path[#simplified_path + 1] = mvec3_cpy(original_path[to])
						from = to
						break
					end
					from = to - 1
					break
				end
		
				to = to + 1
			end
			
			if to > size then
				break
			end
		end
	end

	simplified_path[1] = mvec3_cpy(original_path[1])
	simplified_path[#simplified_path + 1] = mvec3_cpy(original_path[size])

	if apply_padding and #simplified_path > 2 then
		CopActionWalk._apply_padding_to_simplified_path(simplified_path)
		CopActionWalk._calculate_shortened_path(simplified_path)
	end

	if nr_iterations > 1 and #simplified_path > 2 then
		simplified_path = CopActionWalk._calculate_simplified_path(good_pos, simplified_path, nr_iterations - 1, is_host, apply_padding)
	end

	return simplified_path
end