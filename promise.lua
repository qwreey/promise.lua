---@class promise
local promise = {};
promise.__index = promise;
local promises = setmetatable({},{__mode = "v"});
promise.promises = promises;

--#region --* Const *--
local insert = table.insert;
local remove = table.remove;
local wrap = coroutine.wrap;
local yield = coroutine.yield;
local running = coroutine.running;
local resume = coroutine.resume;
local unpack = table.unpack;
local pack = table.pack;
--#endregion --* Const *--
--#region --* Log/Debug *--
---@diagnostic disable
local _,prettyPrint = pcall(require,"pretty-print")
local stdout = type(prettyPrint) == "table" and prettyPrint.stdout
local ioStdout = io.write
function promise.log(err)
	err = "[Promise] " .. err;
	if log and log.error then
		log.error(err);
	elseif logger and logger.error then
		logger.error(err);
	elseif stdout then
		stdout:write(err);
	elseif ioStdout then
		ioStdout(err);
	elseif print then
		print(err);
	end
end
---@diagnostic enable

local function err_unhandled(self,msg)
	return ("Unhandled promise exception on '%s', Error message was\n%s"):format(tostring(self),msg)
end
local function err_spawn(self,msg)
	return ("Error on spawn function '%s', Error message was\n%s"):format(tostring(self),msg)
end
local function err_andThen(self,msg)
	return ("Expectation occurred on running callback function on promise '%s'. (andThen)\n%s"):format(tostring(self),msg)
end
local function err_catch(self,msg)
	return ("Expectation occurred on running callback function on promise '%s'. (catch)\n%s"):format(tostring(self),msg)
end
--#endregion --* Log/Debug *--
--#region --* Promise Class *--
-- tostring function
promise.__tostring = function(self)
	if self == promise then return ("<promise>") end;
	setmetatable(self,nil);
	local this = tostring(self);
	setmetatable(self,promise);
	return ("promise: %s (%s)"):format(this:match("0x.+"),self.__id);
end;

-- execute function when has no error
function promise:andThen(func)
	local __type_func = type(func);
	if __type_func ~= "function" then
		error(("promise:andThen() 1 arg 'func' must be function, but got %s"):format(__type_func));
	end

	if self.__state then
		if self.__passed then
			self.__results = pack(func(unpack(self.__results or {})));
		end
		return self;
	end

	-- insert into list
	local __then = self.__then;
	if not __then then
		__then = {};
		self.__then = __then;
	end
	insert(__then,func);

	return self;
end

-- execute function when has error
function promise:catch(func)
	local __type_func = type(func);
	if __type_func ~= "function" then
		error(("promise:catch() 1 arg 'func' must be function, but got %s"):format(__type_func));
	end

	if self.__state then
		if self.__passed then
			return self;
		end
		self.__results = pack(func(unpack(self.__results or {})));
		return self;
	end

	-- insert into list
	local __catch = self.__catch;
	if not __catch then
		__catch = {};
		self.__catch = __catch;
	end
	insert(__catch,func);

	return self;
end

-- retry execution when errored
function promise:setRetry(num)
	local __type_num = type(num);
	if __type_num ~= "number" then
		error(("promise:setRetry() 1 arg 'num' must be number, but got %s"):format(__type_num));
	end

	if num <= 0 then
		self.__retry = nil;
		return self;
	end

	if self.__state then
		self.__state = nil;
		self.__retry = num - 1;
		local whenRetry = self.__whenRetry;
		if whenRetry then
			whenRetry(unpack(self.__results or {}));
		end
		return self:execute();
	end
	self.__retry = num;

	return self;
end

function promise:getRetry()
	return self.__retry;
end

-- hook for trying, you can use only one function for this
function promise:whenRetry(func)
	local __type_func = type(func);
	if __type_func ~= "function" then
		error(("promise:whenRetry() 1 arg 'func' must be function, but got %s"):format(__type_func));
	end

	self.__whenRetry = func;

	return self;
end

-- state of this promise
function promise:isDone()
	return self.__state,self:isSucceed();
end

-- check promise that succeed
function promise:isSucceed()
	return self.__passed,unpack(self.__results or {});
end

-- check promise that failed
function promise:isFailed()
	return not self.__passed,unpack(self.__results or {});
end

-- return results in table
function promise:getResultsTable()
	return self.__results;
end

-- return results in unpacked table
function promise:getResults()
	return unpack(self:getResultsTable());
end

-- wait for this promise to complete
function promise:wait()
	local thisThread = running();
	if not thisThread then
		error("promise:wait() must be runned on ");
	end
	if self.__state then
		return self;
	end
	local wait = self.__wait;
	if not wait then
		wait = {};
		self.__wait = wait;
	end
	insert(wait,thisThread);
	return yield();
end

-- execute this promise, don't use this directly
function promise:execute()
	wrap(function ()
		local results = pack(pcall(self.__func,unpack(self.__callArgs)));
		self.__state = true;
		local passed = remove(results,1);
		self.__passed = passed;
		self.__results = results;
		if passed then
			local _then = self.__then;
			if _then then
				for _,f in ipairs(_then) do
					results = pack(pcall(f,unpack(results)));
					passed = remove(results,1);
					if not passed then
						promise.log(err_unhandled(self,results[1]));
						break;
					end
				end
				self.__results = results;
				self.__then = nil;
			end
		else
			local retry = self.__retry;
			if retry and (retry > 0) then
				self.__retry = retry - 1;
				local whenRetry = self.__whenRetry;
				if whenRetry then
					whenRetry(unpack(results));
				end
				return self:execute();
			end
			local catch = self.__catch;
			if catch then
				for _,f in ipairs(catch) do
					results = pack(pcall(f,unpack(results)));
					passed = remove(results,1);
					if not passed then
						promise.log(err_catch(self,results[1]));
						break;
					end
				end
				self.__results = results;
			else promise.log(err_unhandled(self,results[1]));
			end
			self.__catch = nil;
		end
		local wait = self.__wait;
		if wait then
			for _,waitter in ipairs(wait) do
				resume(waitter,self);
			end
			self.__wait = nil;
		end
	end)();

	return self;
end

-- make new promise object
local ids = 1;
function promise.new(func,...)
	local __type_func = type(func);
	if __type_func ~= "function" then
		error(("promise.new() 1 arg 'func' must be function, but got %s"):format(__type_func));
	end

	local this = {
		__func = func;
		__callArgs = pack(...);
		__id = ids;
	};

	setmetatable(this,promise);
	promises[ids] = this;
	ids = ids + 1;
	this:execute();

	return this;
end
--#endregion --* Promise Class *--
--#region --* Spawn Function *--
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
--#endregion --* Spawn Function *--
--#region --* Promise Waitter *--
---@class PromiseWaitter
local waitter = {};
waitter.__index = waitter;
function waitter:wait()
	for index,this in ipairs(self) do
		this:wait();
		self[index] = nil;
	end
end
function waitter:add(this)
	return insert(self,this);
end
function promise.waitter()
	return setmetatable({},waitter);
end
--#endregion --* Promise Waitter *--

_G.promise = promise;
return promise;
