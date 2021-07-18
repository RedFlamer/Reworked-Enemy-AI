local math_abs = math.abs

local mvec3_cpy = mvector3.copy

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