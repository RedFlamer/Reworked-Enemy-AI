-- Last area is never set in vanilla so this doesn't do anything
-- Removes duplicate entries from the coarse path
function GroupAIStateBase:_merge_coarse_path_by_area(coarse_path)
	local i_nav_seg = #coarse_path
	local last_area = nil

	while i_nav_seg > 0 do
		if #coarse_path > 2 then -- Check this here instead, saving a little bit of performance
			local nav_seg = coarse_path[i_nav_seg][1]
			local area = self:get_area_from_nav_seg_id(nav_seg)

			if last_area and last_area == area then
				table.remove(coarse_path, i_nav_seg) -- Duplicate entry, remove from the coarse path
			else
				last_area = area -- Normally the vanilla game will not set last_area to the previous area, rendering this function useless
			end
		end

		i_nav_seg = i_nav_seg - 1
	end
end
