local react_shoot = AIAttentionObject.REACT_SHOOT
local react_surprised = AIAttentionObject.REACT_SURPRISED

--[[function CopActionWalk._calculate_simplified_path(good_pos, original_path, nr_iterations, is_host, apply_padding)
	local simplified_path = {good_pos}
	local original_path_size = #original_path

	for i = 1, #original_path do
		local nav_point = original_path[i]
	end

	for i_nav_point, nav_point in ipairs(original_path) do
		if nav_point.x and i_nav_point ~= original_path_size and (i_nav_point == 1 or simplified_path[#simplified_path].x) then
			local pos_from = simplified_path[#simplified_path]
			local pos_to = CopActionWalk._nav_point_pos(original_path[i_nav_point + 1])
			local add_point = is_host and math.abs(nav_point.z - pos_from.z - (nav_point.z - pos_to.z)) > 60
			add_point = add_point or CopActionWalk._chk_shortcut_pos_to_pos(pos_from, pos_to)

			if add_point then
				simplified_path[#simplified_path + 1] = mvec3_cpy(nav_point)
			end
		else
			simplified_path[#simplified_path + 1] = nav_point
		end
	end

	if apply_padding and #simplified_path > 2 then
		CopActionWalk._apply_padding_to_simplified_path(simplified_path)
		CopActionWalk._calculate_shortened_path(simplified_path)
	end

	if nr_iterations > 1 and #simplified_path > 2 then
		simplified_path = CopActionWalk._calculate_simplified_path(good_pos, simplified_path, nr_iterations - 1, is_host, apply_padding)
	end

	return simplified_path
end--]]

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