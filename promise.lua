---@class promise
local promise = {}
promise.__index = promise

local insert = table.insert
local remove = table.remove
local wrap = coroutine.wrap
local yield = coroutine.yield
local running = coroutine.running
local resume = coroutine.resume
local unpack = table.unpack
local pack = table.pack

local _,prettyPrint = pcall(require,"pretty-print")
local stdout = type(prettyPrint) == "table" and prettyPrint.stdout
local ioStdout = io.write
function promise.log(msg)
	if stdout then
		stdout:write(msg)
	elseif ioStdout then
		ioStdout(msg)
	elseif print then
		print(msg)
	end
end

local function err_unhandled(self,msg)
	return ("[Promise] Unhandled promise exception on '%s', Error message was\n          %s"):format(
		tostring(self),msg:gsub("\n","\n          ")
	)
end
local function err_spawn(self,msg)
	return ("[Promise] Error on spawn function '%s', Error message was\n          %s"):format(
		tostring(self),msg:gsub("\n","\n          ")
	)
end

function promise:andThen(func)
	local __type_func = type(func)
	if __type_func ~= "function" then
		error(("promise:andThen() 1 arg 'func' must be function, but got %s"):format(__type_func))
	end

	if self.__state then
		if self.__passed then
			self.__results = pack(func(unpack(self.__results or {})))
		end
		return self
	end

	-- insert into list
	local __then = self.__then
	if not __then then
		__then = {}
		self.__then = __then
	end
	insert(__then,func)

	return self
end

-- is error in there
function promise:catch(func)
	local __type_func = type(func)
	if __type_func ~= "function" then
		error(("promise:catch() 1 arg 'func' must be function, but got %s"):format(__type_func))
	end

	if self.__state then
		if self.__passed then
			return self
		end
		self.__results = pack(func(unpack(self.__results or {})))
		return self
	end

	-- insert into list
	local __catch = self.__catch
	if not __catch then
		__catch = {}
		self.__catch = __catch
	end
	insert(__catch,func)

	return self
end

function promise:setRetry(num)
	local __type_num = type(num)
	if __type_num ~= "number" then
		error(("promise:setRetry() 1 arg 'num' must be number, but got %s"):format(__type_num))
	end

	if num <= 0 then
		self.__retry = nil
		return self
	end

	if self.__state then
		self.__state = nil
		self.__retry = num - 1
		local whenRetry = self.__whenRetry
		if whenRetry then
			whenRetry(unpack(self.__results or {}))
		end
		return self:execute()
	end
	self.__retry = num

	return self
end

function promise:getRetry()
	return self.__retry
end

function promise:whenRetry(func)
	local __type_func = type(func)
	if __type_func ~= "function" then
		error(("promise:whenRetry() 1 arg 'func' must be function, but got %s"):format(__type_func))
	end

	self.__whenRetry = func

	return self
end

function promise:isDone()
	return self.__state,self:isSucceed()
end

function promise:isSucceed()
	return self.__passed,unpack(self.__results or {})
end

function promise:isFailed()
	return not self.__passed,unpack(self.__results or {})
end

function promise:getResultsTable()
	return self.__results
end

function promise:getResults()
	return unpack(self:getResultsTable())
end

-- wait for end
function promise:wait()
	local thisThread = running()
	if not thisThread then
		error("promise:wait() must be runned on ")
	end
	if self.__state then
		return self
	end
	local wait = self.__wait
	if not wait then
		wait = {}
		self.__wait = wait
	end
	insert(wait,thisThread)
	return yield()
end

function promise:execute()
	wrap(function ()
		local results = pack(pcall(self.__func,unpack(self.__callArgs)))
		self.__state = true
		local passed = remove(results,1)
		self.__passed = passed
		self.__results = results
		if passed then
			local _then = self.__then
			if _then then
				for _,f in ipairs(_then) do
					results = pack(f(unpack(results)))
				end
				self.__results = results
				self.__then = nil
			end
		else
			local retry = self.__retry
			if retry and (retry > 0) then
				self.__retry = retry - 1
				local whenRetry = self.__whenRetry
				if whenRetry then
					whenRetry(unpack(results))
				end
				return self:execute()
			end
			local catch = self.__catch
			if catch and #catch ~= 0 then
				for _,f in ipairs(catch) do
					results = pack(f(unpack(results))) -- err, ...
				end
				self.__results = results
			else
				promise.log(err_unhandled(self,results[1]))
			end
			self.__catch = nil
		end
		local wait = self.__wait
		if wait then
			for _,waitter in ipairs(wait) do
				resume(waitter,self)
			end
			self.__wait = nil
		end
	end)()

	return self
end

function promise.new(func,...)
	local __type_func = type(func)
	if __type_func ~= "function" then
		error(("promise.new() 1 arg 'func' must be function, but got %s"):format(__type_func))
	end

	---@type promise
	local this = {
		__func = func;
		__callArgs = pack(...);
	}
	setmetatable(this,promise)
	this:execute()
	return this
end

local traceback = debug.traceback
local function pspawn_err(err)
	promise.log(err_spawn(tostring(err),tostring(traceback())))
end
local function pspawn(func,...)
	xpcall(func,pspawn_err,...)
end
function promise.spawn(func,...)
	wrap(pspawn)(func,...)
end

---@class promise_waitter
local waitter = {}
waitter.__index = waitter
function waitter:wait()
	for index,this in ipairs(self) do
		this:wait()
		self[index] = nil
	end
end
function waitter:add(this)
	return insert(self,this)
end
function promise.waitter()
	return setmetatable({},waitter) ---@type promise_waitter
end

_G.promise = promise
return promise
