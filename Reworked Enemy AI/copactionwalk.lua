local mvec3_set = mvector3.set
local mvec3_z = mvector3.z
local mvec3_set_z = mvector3.set_z
local mvec3_sub = mvector3.subtract
local mvec3_norm = mvector3.normalize
local mvec3_add = mvector3.add
local mvec3_mul = mvector3.multiply
local mvec3_lerp = mvector3.lerp
local mvec3_cpy = mvector3.copy
local mvec3_set_l = mvector3.set_length
local mvec3_dot = mvector3.dot
local mvec3_cross = mvector3.cross
local mvec3_dis = mvector3.distance
local mvec3_dis_sq = mvector3.distance_sq
local mvec3_len = mvector3.length
local mvec3_rot = mvector3.rotate_with
local mvec3_set_static = mvector3.set_static
local mrot_lookat = mrotation.set_look_at
local mrot_slerp = mrotation.slerp
local mrot_yaw = mrotation.yaw
local math_abs = math.abs
local math_max = math.max
local math_min = math.min

local tmp_vec1 = Vector3(0, 0, 0)
local tmp_vec2 = Vector3(0, 0, 0)
local tmp_vec3 = Vector3(0, 0, 0)
local tmp_vec4 = Vector3(0, 0, 0)

local react_shoot = AIAttentionObject.REACT_SHOOT
local react_surprised = AIAttentionObject.REACT_SURPRISED

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

-- honestly fuck this code, this is painful even with the dev comments from an old lua source

-- As a client, should the first entry in self._nav_path be the unit position upon starting the path?
-- So upon interruption or other potential circumstances, should we set the first entry to be the unit position?
-- If we deviate from our path, would setting the first entry to be the unit position result in enemies moving through walls?
-- If so, we should return to the point in which we deviated from the path
-- If our deviation would still be valid for moving to the next nav point, we should just allow the enemy to take the path
-- Otherwise utilising m_host_stop_pos should allow us to return to where we deviated and continue from there
-- Therefore preventing the enemy from taking an invalid path, but the enemy will still have desynced from their true position, catching up is necessary

-- There also seems to be a mistake, clients waiting for _upd_wait_for_full_blend could still receive navpoints that would go unaccounted for
function CopActionWalk:_init()
	if not self:_sanitize() then
		return
	end

	self._init_called = true
	self._walk_velocity = self:_get_max_walk_speed()
	local action_desc = self._action_desc
	local common_data = self._common_data

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
				return false -- TODO: Does this ever actually occur?
			end		
		end

		self._nav_path = nav_path
	else
		if not action_desc.interrupted or not self._nav_path[1].x then -- Didn't interrupt, or point 1 in the nav path is a navlink
			table.insert(self._nav_path, 1, mvec3_cpy(common_data.pos))
		else
			self._nav_path[1] = mvec3_cpy(common_data.pos) -- This could lead to the enemy potentially walking through a wall to reach the 2nd navpoint? should we use m_host_stop_pos here to prevent it?
		end

		local nav_path = self._nav_path

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

		if not action_desc.host_stop_pos_ahead and self._nav_path[2] then
			local ray_params = {
				tracker_from = common_data.nav_tracker,
				pos_to = self._nav_point_pos(self._nav_path[2])
			}

			if managers.navigation:raycast(ray_params) then
				table.insert(self._nav_path, 2, mvec3_cpy(self._ext_movement:m_host_stop_pos()))

				self._host_stop_pos_ahead = true
			end
		end
	end

	if action_desc.path_simplified and action_desc.persistent then
		if self._sync then
			local t_ins = table.insert
			local original_path = self._nav_path
			local new_nav_points = self._simplified_path
			local s_path = {}
			self._simplified_path = s_path

			for _, nav_point in ipairs(original_path) do
				t_ins(s_path, nav_point.x and mvec3_cpy(nav_point) or nav_point)
			end

			if new_nav_points then
				for _, nav_point in ipairs(new_nav_points) do
					t_ins(s_path, nav_point.x and mvec3_cpy(nav_point) or nav_point)
				end
			end
		else
			self._simplified_path = self._nav_path
		end
	elseif not managers.groupai:state():enemy_weapons_hot() then
		self._simplified_path = self._nav_path
	else
		local good_pos = mvector3.copy(common_data.pos)
		self._simplified_path = self._calculate_simplified_path(good_pos, self._nav_path, (not self._sync or self._common_data.stance.name == "ntl") and 2 or 1, self._sync, true)
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

	if #self._simplified_path == 2 and not self._NO_RUN_STOP and not self._no_walk and self._haste ~= "walk" and mvec3_dis(self._curve_path[2], self._curve_path[1]) >= 120 then
		self._chk_stop_dis = 210
	end

	if Network:is_server() then
		local sync_yaw = 0

		if self._end_rot then
			local yaw = self._end_rot:yaw()

			if yaw < 0 then
				yaw = 360 + yaw
			end

			sync_yaw = 1 + math.ceil(yaw * 254 / 360)
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

			nav_link_act_yaw = math.ceil(255 * nav_link_act_yaw / 360)

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

	if Network:is_server() then
		self._unit:brain():rem_pos_rsrv("stand")
		self._unit:brain():add_pos_rsrv("move_dest", {
			radius = 30,
			position = mvector3.copy(self._simplified_path[#self._simplified_path])
		})
	end

	return true
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