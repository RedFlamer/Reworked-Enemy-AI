-- Picture this: a task is queued with a low timer, it needs to be inserted at position 5 in the main table and the main table has 100 entries
-- We have to check the timer on 95 other tasks to find the position for the task to be inserted
-- Which isn't so bad if there's only a few low timer tasks queued, but if we're comparing 95 timers every time there's a low timer task queued, that is pretty inefficient
-- Whereas the to_merge table will significantly cut the amount of timers we have to check, so it's more like comparing 30 timers 5 times
-- And then comparing the 95 timers and merging all 5 of the low timer tasks into that position at once, instead of separately
-- In this case resulting in 30 * 5 + 95 = 245 timer comparisons
-- Whereas not aggregating them results in 95 * 5 = 475 timer comparisons which is notably less efficient, even in this absolute best case scenario

-- In any case, avoid comparing timers to find a position on the main table due to it's larger size and aggregate them all to be added at once with a to_merge table
-- Minimising the amount of times we need to check the timer on each task in the main table to once unless we need to add any tasks into that position

-- This is necessary to mitigate the issues of sorting the task table by timer and preserve the benefits, such as allowing reindexing the table to be more efficient
-- So if the first 10 tasks are executed in the table, we can create a new table with tasks 11 onwards

-- This is pretty much the best solution i could come up with to be as efficient as possible under a high tickrate scenario

Hooks:PostHook(EnemyManager, "init", "REAI_init", function(self)
	self._queued_tasks_timerless = {}
	self._to_merge = {}
end)

function EnemyManager:queue_task(id, task_clbk, data, execute_t, verification_clbk, asap)
	if not execute_t and #self._queued_tasks < 1 and not self._queued_task_executed then
		self._queued_task_executed = true

		if verification_clbk then
			verification_clbk(id)
		end

		task_clbk(data)
	else
		local task_data = {
			clbk = task_clbk,
			id = id,
			data = data,
			t = execute_t,
			v_cb = verification_clbk,
			asap = asap
		}
		
		if not execute_t then
			self._queued_tasks_timerless[#self._queued_tasks_timerless + 1] = task_data
			-- By just appending the timerless task to the end of the timerless table as soon as it's queued, the table will always preserve the first task as the oldest
			-- This also saves checking every single timer on the main table to find a position, since we know it has no timer
		elseif #self._queued_tasks == 0 then
			self._queued_tasks[#self._queued_tasks + 1] = task_data -- Ensure that we can reindex without having to check that there already is a queued task
		else
			-- If the task has a timer, add it to a table to be merged with self._queued_tasks after we're done executing tasks and reindexing the table
			-- There is no situation in which it is necessary to merge a task with a timer into self._queued_tasks immediately after it gets queued
			-- As if the task has a timer it is guaranteed not to be ready to be executed on the same frame it is queued
			-- This allows us aggregate position finding for newly queued tasks, instead of comparing timers in the main table for every single task that gets queued
			-- Since the to_merge table almost certainly will have significantly less entries than the main task table, this should save performance
			local to_merge_table = self._to_merge
			local to_merge_table_size = #to_merge_table
			local insert_position = to_merge_table_size
			
			while insert_position > 0 and execute_t < to_merge_table[insert_position].t do
				insert_position = insert_position - 1
			end
			
			if insert_position == to_merge_table_size then
				to_merge_table[#to_merge_table + 1] = task_data
				-- Task has a longer timer than every other task, no need to remake the table
			else
				-- We need to remake the to_merge table with the task
				-- Better to do this a lot on the smaller to_merge table and then do it once on the larger main table than do it a lot on the main table
				local to_merge_remake = {}
			
				for i = 1, insert_position do
					to_merge_remake[#to_merge_remake + 1] = to_merge_table[i]
				end
				
				to_merge_remake[#to_merge_remake + 1] = task_data
				
				for i = insert_position + 1, to_merge_table_size do
					to_merge_remake[#to_merge_remake + 1] = to_merge_table[i]
				end
		
				self._to_merge = to_merge_remake
			end
		end
	end
end

function EnemyManager:update_queue_task(id, task_clbk, data, execute_t, verification_clbk, asap)
	-- This becomes a little bit of a hassle because of having three separate tables the task could potentially be in
	local task_not_merged = false
	local task_is_timerless = false
	
	local task_data, _ = table.find_value(self._queued_tasks, function (td)
		return td.id == id
	end)

	if not task_data and self._queued_tasks_timerless then
		task_data, _ = t_fv(self._queued_tasks_timerless, function (td)
			return td.id == id
		end)
		
		if task_data then
			task_is_timerless = true
		end
	end
	
	if not task_data and self._to_merge then
		task_data, _ = t_fv(self._to_merge, function (td)
			return td.id == id
		end)
		
		if task_data then
			task_not_merged = true
		end
	end

	if task_data then
		local needs_renewing = false
		if task_data.t ~= execute_t or not task_data.t and execute_t then
			needs_renewing = true -- Since we sort by timer and have a separate table for timerless it is necessary to renew the task
		end
	
		task_data.clbk = task_clbk or task_data.clbk
		task_data.data = data or task_data.data
		task_data.t = execute_t or task_data.t
		task_data.v_cb = verification_clbk or task_data.v_cb
		task_data.asap = asap or task_data.asap
		
		if needs_renewing then
			self:unqueue_task(id, task_is_timerless, task_not_merged)
			self:queue_task(id, task_data.clbk, task_data.data, task_data.t, task_data.v_cb, task_data.asap)	
		end
	end
end

function EnemyManager:unqueue_task(id, task_is_timerless, task_not_merged)
	if task_not_merged then
		local tasks = self._to_merge
	elseif task_is_timerless then
		local tasks = self._queued_tasks_timerless
	else
		local tasks = self._queued_tasks
	end
	
	if tasks then
		local i = #tasks
		while i > 0 do
			if tasks[i].id == id then
				table.remove(tasks, i)

				return
			end

			i = i - 1
		end
	end

	-- In case the checked table didn't have the task, double check the others
	if task_is_timerless == nil then
		self:unqueue_task(id, true, false)
	elseif task_not_merged == nil then
		self:unqueue_task(id, true, true)
	end
end

function EnemyManager:has_task(id, task_is_timerless, task_not_merged)
	if task_not_merged then
		local tasks = self._to_merge
	elseif task_is_timerless then
		local tasks = self._queued_tasks_timerless
	else
		local tasks = self._queued_tasks
	end
	
	local count = 0	
	
	if tasks then	
		local i = #tasks
		while i > 0 do
			if tasks[i].id == id then
				count = count + 1
			end

			i = i - 1
		end
	end

	-- In case the checked table didn't have the task, double check the others
	if count > 0 then
		return count
	elseif task_is_timerless == nil then
		self:has_task(id, true, false)
	elseif task_not_merged == nil then
		self:has_task(id, true, true)
	end	
end

-- Don't use table.remove or anything, the table will be remade after we finish executing tasks for the frame
function EnemyManager:_execute_queued_task(i, timerless)
	local task = timerless and self._queued_tasks_timerless[i] or self._queued_tasks[i]
	
	self._queued_task_executed = true

	if task.v_cb then
		task.v_cb(task.id)
	end

	task.clbk(task.data)
end

-- Ignoring asap tasks for now because they just wouldn't work cleanly with how the table is reindexed
-- Could handle them by remaking the entire table but can't aggregate it with other tasks
function EnemyManager:_update_queued_tasks(t, dt)
	local tasks_executed = 0
	local done = false
	
	self._queue_buffer = self._queue_buffer + dt
	local tick_rate = 0.001666666666

	if tick_rate <= self._queue_buffer then
		local timerless = self._queued_tasks_timerless
		if timerless and timerless[1] then
			self:_execute_queued_task(1, true) -- Just do one timerless task per frame

			self:_reindex_timerless(2)
			
			self._queue_buffer = self._queue_buffer - tick_rate

			if self._queue_buffer <= 0 then
				done = true
			end	
		end
		
		if not done then
			local queued_tasks = self._queued_tasks
			for i = 1, #queued_tasks do
				if queued_tasks[i].t < t then
					self:_execute_queued_task(i, false)
					
					self._queue_buffer = self._queue_buffer - tick_rate

					if self._queue_buffer <= 0 then
						tasks_executed = i
						break
					end
				else
					tasks_executed = i - 1
					break
				end
			end
		end
	end

	if #self._queued_tasks == 0 and (not self._queued_tasks_timerless or #self._queued_tasks_timerless == 0) then
		self._queue_buffer = 0
	end

	local all_clbks = self._delayed_clbks

	if all_clbks[1] and all_clbks[1][2] < t then
		local clbk = table.remove(all_clbks, 1)[3]

		clbk()
	end

	if self._queued_task_executed or #self._to_merge > 0 then
		self:_reindex_timer(tasks_executed)
	end
end

function EnemyManager:_reindex_timer(tasks_executed)
	local queued_tasks = self._queued_tasks
	local queued_tasks_length = #queued_tasks
	local to_merge = self._to_merge
	local to_merge_length = #to_merge

	local total_tasks = #queued_tasks + #to_merge - tasks_executed

	local new_timer = {}

	-- Going backwards should be more efficient here, since it'd clear out the to_merge table faster
	-- As generally newly queued tasks would likely have longer timers than tasks that have been waiting
	-- It's safe to assume that we won't queue an already executed task again due to the timer
	for i = total_tasks, 1, -1 do
		local to_merge_task = to_merge[to_merge_length]
		local existing_task = queued_tasks[queued_tasks_length]
		
		if to_merge_task and to_merge_task.t > existing_task.t then
			new_timer[i] = to_merge_task -- The task to merge has a greater time than the next, insert it
			
			to_merge_length = to_merge_length - 1
		else
			new_timer[i] = existing_task 
			
			queued_tasks_length = queued_tasks_length - 1
		end
	end

	self._to_merge = {}
	self._queued_tasks = new_timer
end

function EnemyManager:_reindex_timerless(reindex_from)
	local timerless_tasks = self._queued_tasks_timerless
	local new_timerless = {}

	for i = reindex_from, #timerless_tasks do
		new_timerless[#new_timerless + 1] = timerless_tasks[i]
	end
	
	self._queued_tasks_timerless = new_timerless
end