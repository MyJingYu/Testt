--[[
 *  
 --]]
local GameMediator = require('Game.PureMVC.mediator.GameMediator')
local PureMVCBattleEvents = require "PureMVCBattleEvents"
local PureMVCEvents = require ("Game.PureMVC.PureMVCEvents")
local cfg_specialEffects = require "cfg_specialEffects"
local luaTbl = require("UnTables")
local baseMain = require"Common/BaseMain"

local CActorWorld = class('CActorWorld')
function CActorWorld:ctor()
    self:InitData()
    self:InitMediator()
end

function CActorWorld:InitMediator()
    self.m_mediator = nil
    if self.m_mediator == nil then
        self.m_mediator = GameMediator.new("CActorWorld",self)
        self.m_mediator:registerMediator()
    end
end

function CActorWorld.GetInstance()
	if nil == CActorWorld.instance then
		CActorWorld.instance = CActorWorld.new()
		return CActorWorld.instance
	else
		return CActorWorld.instance
	end
end


function CActorWorld:InitData()
	self.arrEntity = {}
end

function CActorWorld:Init(curWorld,logicMain)
    self:InitData()

	self.curWorld = curWorld
	self.logicMain = logicMain

	self.bPause = false;

	self.bBlackCover = false; --是否黑色遮罩
end

function CActorWorld:listNotificationInterests()
    return {PureMVCBattleEvents.PMVCEvent_BattleMsg}
end

function CActorWorld:Tick(DeltaSeconds)
	for k, v in pairs(self.arrEntity) do
		self:updateActorPosAndFace(k,v)

		if v.Tick then
			v:Tick(DeltaSeconds);
		end
  	end
end

function CActorWorld:handleNotification(notification)
    --printError("handleNotification~~~~~~~~~~~~~~~~~~~~~~~~")

	local body = notification.body;
	local name = notification.name;

	if name ~= PureMVCBattleEvents.PMVCEvent_BattleMsg then
		return
	end

	if body.key == PureMVCBattleEvents.PMVCEvent_CreateUnit then
		self:CreatUnit(body)
	elseif body.key == PureMVCBattleEvents.PMVCEvent_CreateEffect then
		self:CreatEffect(body)
	elseif body.key == PureMVCBattleEvents.PMVCEvent_PlayAnima then
		self:PlayAnima(body)
	elseif body.key == PureMVCBattleEvents.PMVCEvent_RemoveEntity then
		self:RemoveEntity(body)
	elseif body.key == PureMVCBattleEvents.PMVCEvent_UnitHpChange then
		self:UnitHpChange(body)
	elseif body.key == PureMVCBattleEvents.PMVCEvent_UnitDead then
		self:UnitDead(body);
	elseif body.key == PureMVCBattleEvents.PMVCEvent_BattleOver then
		self:BattleOver(body)
	end
end



function CActorWorld:sendNotification(notificationName, body, type)
    if self.m_mediator ~= nil then
        self.m_mediator:sendNotification(notificationName,body,type)
    end
end

function CActorWorld:BattleOver(body)
	--这里弹ui
	local facade = pm.Facade.getInstance('GameFacade')
	facade:sendNotification("BattleEvent_End",{bWin=body.bWin});
	
	local copyLogic = baseMain:Instance():getCurCopyLogic();
	if copyLogic then
		copyLogic:endCopyBattle(true);
	end
end

function CActorWorld:GetEntity(globalID)
	return self.arrEntity[globalID]
end

function CActorWorld:RemoveEntity(body)
	if self.arrEntity[body.globalID] ~= nil then
		if self.arrEntity[body.globalID].onRemoveEntity then
			self.arrEntity[body.globalID]:onRemoveEntity();
		end

		--[[
			zxj
		]]
		self:sendNotification(PureMVCEvents.MapBlackCover_RemoveShowOnlyActor,{act = self.arrEntity[body.globalID]});
		self.arrEntity[body.globalID]:K2_DestroyActor()
		self.arrEntity[body.globalID] = nil
	end
end

function CActorWorld:UnitHpChange(body)
	--printWarn("===========CActorWorld:UnitHpChange(body) ")
	local unit = self.arrEntity[body.globalID];
	if unit ~= nil then
		unit:UnitHpChange(body)
		
		--[[
			zxj
			在遮罩时受到伤害的目标高亮
		]]
		if unit and self.bBlackCover then
			self:sendNotification(PureMVCEvents.MapBlackCover_AddShowAct,{addShowAct = unit});
		end
	end
end

function CActorWorld:UnitDead(body)
	local act = self.arrEntity[body.globalID]
	if act ~= nil and act.Dead then
		act:Dead();
	end
end

function CActorWorld:PlayAnima(body)
	if self.arrEntity[body.globalID] ~= nil then
		if body.strAnima == "run" then
			--[[
				策划需求
				出场时，跑步动作的初始帧数随机一下，尽量让同模型的角色/怪物跑步动作不一致
			]]
			self.arrEntity[body.globalID]:PlayAnimaByName(body.strAnima,math.random()*3)
		else
			self.arrEntity[body.globalID]:PlayAnimaByName(body.strAnima,0)
		end
	end
end

function CActorWorld:CreatEffect(body)
	local tbl = cfg_specialEffects[body.id]
	local actor = self.curWorld:SpawnActor(UE4.UClass.Load(tbl.route), 
											nil, ESpawnActorCollisionHandlingMethod.AlwaysSpawn, self, nil);

	self.arrEntity[body.globalID] = actor
	actor:Init(body.globalID,body.id);

	--[[
		zxj
		在暂停时产生的特效是不暂停的
	]]
	if self.bPause then
		local entity = self.logicMain:GetEntityByGlobalId(body.globalID)
		if entity == nil then
			return
		end
		actor:SetPauseOrResume(entity:IfPause());
	end

	--[[
		zxj
		在遮罩时产生的特效时高亮的
	]]
	if actor and self.bBlackCover then
		self:sendNotification(PureMVCEvents.MapBlackCover_AddShowAct,{addShowAct = actor});
	end
end

function CActorWorld:CreatUnit(body)
	local id = body.id;
	local cardTbl;

	if body.bMonster then
		cardTbl = luaTbl:GetTableByNameAndID("cfg_monsterCards",id);
	else
		cardTbl = luaTbl:GetTableByNameAndID("cfg_cards",id);
	end

	if cardTbl then
		local tbl = luaTbl:GetTableByNameAndID("cfg_model",cardTbl.model);
		if tbl then
			-- local actor = self.curWorld:SpawnActor(UE4.UClass.Load("/Game/BluePrints/Battle/Unit/Hero/BP_Hero1.BP_Hero1"), 
			-- 										nil, ESpawnActorCollisionHandlingMethod.AlwaysSpawn, self, nil);
			-- print("@@@@@@@@@@:"..tbl.resource)
			local actor = self.curWorld:SpawnActor(UE4.UClass.Load(tbl.resource), 
													nil, ESpawnActorCollisionHandlingMethod.AlwaysSpawn, self, nil);

			self.arrEntity[body.globalID] = actor
			actor:Init(body.globalID,body.camp)

		else
			printError("CActorWorld CreatUnit id:"..tostring(id).." in cfg_model is nil");
		end
	end
end


function CActorWorld:updateActorPosAndFace(globalId,actor)
	local entity = self.logicMain:GetEntityByGlobalId(globalId)
	if entity == nil then
		return
	end

	actor:SetPosition(entity:GetPosition())
	actor:SetRotate(entity:GetTargetPos())
	-- actor:SetPauseOrResume(entity:IfPause())
 end


 --[[
	 zxj
	 @bIfMuanulPauseBattle 识别手动暂停
 ]]
 function CActorWorld:OnPauseOrResumeBattle(bPause,bIfMuanulPauseBattle)
	self.bPause = bPause;

	self.bBlackCover = false; --是否黑色遮罩
	local arrHighLightAct = {}; --高亮角色
	if bPause and bIfMuanulPauseBattle == false then --手动暂停先不要遮罩
		self.bBlackCover = true;
	end

	for k, v in pairs(self.arrEntity) do
		local entity = self.logicMain:GetEntityByGlobalId(k)
		if entity == nil then
			return
		end
		v:SetPauseOrResume(entity:IfPause());

		if self.bBlackCover and entity:IfPause()==false then
			table.insert(arrHighLightAct,v);
			-- printError("gggggg:"..entity:GetGlobalId());

			--[[ 
				zxj
				策划需求
				目标也高亮]]
			local targetEntity = entity:GetTargetUnit();
			if targetEntity and targetEntity:IfDead() == false then
				local act = self.arrEntity[targetEntity:GetGlobalId()];
				--printError("ttttttttt:"..targetEntity:GetGlobalId());
				if act then
					table.insert(arrHighLightAct,act);
				end
			end
		end
	end

	local body = {
		bBlackCover = self.bBlackCover,
		arrHighLightAct = arrHighLightAct
	}
	self:sendNotification(PureMVCEvents.MapBlackCover_ShowOrHide,body);
	-- for key, value in pairs(arrHighLightAct) do
	-- 	self:sendNotification(PureMVCEvents.MapBlackCover_AddShowAct,{addShowAct=value})
	-- end

	--[[需求 遮罩时隐藏血条]]
	if self.bBlackCover then
		-- self:sendNotification(PureMVCEvents.Battle_HideAllFollowUI,{});
		for key, value in pairs(self.arrEntity) do
			if value and value.SetFollowUIVisibility then
				value:SetFollowUIVisibility(false);
			end
		end
	end
end


function CActorWorld:OnBlackCoverAddOutlineActor(globalId)
	local actor = self.arrEntity[globalId];
	if actor then
		local body ={
			act = actor;
		}
		self:sendNotification(PureMVCEvents.MapBlackCover_AddOutlineActor,body)
	end
end


function CActorWorld:OnRemoveOutlineActor(globalId)
	local actor = self.arrEntity[globalId];
	if actor then
		local body ={
			act = actor;
		}
		self:sendNotification(PureMVCEvents.MapBlackCover_RemoveOutlineActor,body)
	end
end


function CActorWorld:OnBlackCoverOutlineShutdown()
	self:sendNotification(PureMVCEvents.MapBlackCover_OutlineShutdown)
end


function CActorWorld:End()
	for k, v in pairs(self.arrEntity) do
		v:K2_DestroyActor()
 	end

 	self.arrEntity = {}
end


function CActorWorld:GetEntityByGlobalId(globalId)
	local entity = self.logicMain:GetEntityByGlobalId(globalId);
	return entity;
end

return CActorWorld