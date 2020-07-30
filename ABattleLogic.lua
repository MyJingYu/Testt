--[[
    zxj
    gamemode附加的ActorLogic
    用于处理战斗流程（开始/结束）

    gamemode需要调用接口{
        LuaBegin
        LuaEnd
        LuaTick
    }
]]

require "UnLua"
local PureMVCEvents = require "PureMVCEvents"
local BaseMain = require "Common/BaseMain"
local RGameManager = require "Fight/Rendering/RGameManager"
local LGameManager = require "Fight/Logic/LGameManager"
local Entry = require "Fight/Entry"
local Define = require "Fight/Logic/Define"
local LayerMgr = require("Libs.UI.UserWidgetLayerMgr")
local VInt3 = require "Utils/FixedPoint/VInt3"
local cfg_battleFormation = require "cfg_battleFormation"
local cfg_monsterTeams = require "cfg_monsterTeams"
local cfg_unit = require "cfg_unit"
local cfg_skills = require "cfg_skills" 
local cfg_elementEffect = require "cfg_elementEffect"
local StringUtil = require "Utils/StringUtil"
local ActorObjPoolMgr = require "Libs/ActorObjPool/ActorObjPoolMgr"
local Configs = require "Fight/Configs"
local RandomUtil = require "Utils/RandomUtil"

local LGameData = require "Fight/Logic/GameData/LGameData"
local LLevelEntityData = require "Fight/Logic/GameData/LLevelEntityData"

local ABattleLogic = _G.Class("Game/PureMVC/mediator/BeMediator")

ABattleLogic.battleMap = nil; --战斗流场景
ABattleLogic.battleSequenceMap = nil; --战斗sequence展示流场景

function ABattleLogic:LuaBegin(gameMode)
    self:InitMediator("ABattleLogic");

    self.gameMode = gameMode;
    self.isInBattle = false;

    local result;
    if self.battleMap == nil then
        result, self.battleMap = UE4.ULevelStreamingDynamic.LoadLevelInstance(self:GetWorld(),"BattleTestMapTemp",FVector(0,0,0));
        -- result, self.battleMap = UE4.ULevelStreamingDynamic.LoadLevelInstance(self:GetWorld(),"BattleTestMapTemp",FVector(0,0,0));
    end
    if self.battleSequenceMap == nil then
        result, self.battleSequenceMap = UE4.ULevelStreamingDynamic.LoadLevelInstance(self:GetWorld(),"BattleTestMap");
    end

    self.battleMap:SetShouldBeVisible(true);
    self.battleSequenceMap:SetShouldBeVisible(false);

    self.arrBattleActor = {};

    self.bTestBattle = false;
end

function ABattleLogic:LuaEnd()
    self:removeMediator();

    self:hideAllBattleText();
end

function ABattleLogic:LuaTick(dt)
    if self.isInBattle == true then
        Entry:Tick(dt);
    end
end

function ABattleLogic:BeginBattle(body,bTets)
    print("ABattleLogic:BeginBattle()")
    table_print(body)
    self.isInBattle = true;
    self.battleMap:SetShouldBeVisible(true);

    local camera = UE4.ULuaCallCppFunctionLib.FindSceneActorByName("BattleCamera" , self:GetWorld())
    if camera then
        local controller = UE4.UGameplayStatics.GetPlayerController(self:GetWorld(),0)
        controller:SetViewTargetWithBlend(camera)
    end

    self:PlayCameraMoveSequence();

   
    Configs.bTestBattle = bTets;
    self.bTestBattle = bTets;
    if self.bTestBattle then
        Entry:Begin(self:GetWorld(),self:HardCodeData());
    else
        Entry:Begin(self:GetWorld(),self:ParseData(body));
    end
    
end
local testBody
function ABattleLogic:ParseTestBody()
    return self:ParseData(testBody)
end

function ABattleLogic:ParseData(body)
    LGameData.Clear()
    --解析战斗数据
    local monsterGrpId = body["iMonsterGrpId"]
    local cardInfos = body["arrCardInfo"]
    local isRaid = body["bIsRaid"] --突袭
    local mapId = body["iFightMapId"]
    local randomseed = body["iRandomSeed"]
    local playerInfo = body["kPlayerInfo"]--玩家信息 保存阵型信息

    local posInfos;

    if isRaid then
        posInfos = cfg_battleFormation[tonumber(playerInfo["iTeamType"])]["coordinate2"]
    else
        posInfos = cfg_battleFormation[tonumber(playerInfo["iTeamType"])]["coordinate"]
    end

    printWarn("zxj  isRaid:",isRaid);
    LGameData.Initialize(mapId,randomseed,isRaid)

    local poss = StringUtil.ToStringArray_symbol_2(posInfos)
    for k,v in pairs(cardInfos) do
        local data = LLevelEntityData.new()
        local cardId = v["iCardId"]
        local seatId = v["iSeat"]
        local props = v["kAttrList"]
        local currHp = v["iCurHp"]

        --解析技能
        local skills = {}
        for key, value in pairs(v["arrSkillList"]) do
            table.insert(skills, tonumber(value["iSkillId"]))
        end

        local buffs = v["arrBuffList"]
        for kk,vv in pairs(buffs) do
            local elementCfg = cfg_elementEffect[tonumber(vv["iBuffId"])]
            if elementCfg.skillsId ~= 0 then
                table.insert(skills, tonumber(elementCfg.skillsId))
            end
        end

        --获取普攻,和暴击普攻
        local unitCfg = cfg_unit[tonumber(cardId)]

        local normalAttackCfg = cfg_skills[tonumber(unitCfg.skill1)]
        if normalAttackCfg == nil then
            printError("normalAttackCfg is nil : skillId",tostring(unitCfg.skill1),"cardId",cardId)
        end
        local critAttackId = normalAttackCfg.atkCrit
        table.insert(skills,tonumber(unitCfg.skill1))
        table.insert(skills,tonumber(unitCfg.critAttackId))
        ------------------------------------
        --解析位置
        local pos = StringUtil.ToStringArray(poss[seatId])

        data.cardId = cardId
        data.skillIds = skills
        data.props = props

        --服务端要求特殊处理 当前血量值
        data.props[-1] = currHp


		data.pos = VInt3.new(tonumber(pos[1]),tonumber(pos[2]),tonumber(pos[3]))
        data.posRowIndex = tonumber(pos[4])

        LGameData.AddDataA(data)
    end

    --解析位置信息

    local idsB, posInfosB = self:GetMonsterIdsAndPosInfos(isRaid,monsterGrpId);

    for k,v in pairs(idsB) do
        local data = LLevelEntityData.new()
        local cardId = tonumber(v)
        local skills = {}
        local unitCfg = cfg_unit[cardId]
        local tmps = StringUtil.ToStringArray_symbol_2(unitCfg.skill2)
        for key, value in pairs(tmps) do
            table.insert(skills,tonumber(value))
        end
        table.insert(skills,tonumber(unitCfg.skill1))

        local pos = StringUtil.ToStringArray(posInfosB[k])

        data.cardId = cardId
        data.skillIds = skills
        data.pos = VInt3.new(tonumber(pos[1]),tonumber(pos[2]),tonumber(pos[3]))
        data.posRowIndex = tonumber(pos[4])

        LGameData.AddDataB(data)
    end

    table_print(LGameData)
    return LGameData
end

--获得怪物ids 和 posInfos
function ABattleLogic:GetMonsterIdsAndPosInfos(isRaid,monsterGrpId)
    local monsterTeamsCfg = cfg_monsterTeams[monsterGrpId]
    local idsB = StringUtil.ToStringArray(monsterTeamsCfg["ranks"])

    local randomIndex;

    --突袭战斗增加怪物
    if isRaid then
        local idsBAdd = StringUtil.ToStringArray(monsterTeamsCfg["addMonsters"]);

        if #idsBAdd > 3 then --数量大于3个，那就随机取3个

            for i = 1, 3, 1 do
                randomIndex = RandomUtil.Range(1,#idsBAdd);

                table.insert(idsB,idsBAdd[randomIndex]);
                table.remove(idsBAdd,randomIndex);
            end
        else

            for i = 1, #idsBAdd, 1 do
                table.insert(idsB,idsBAdd[i]);
            end
        end
    end

    --初始位置

    local posInfos;
    local posInfosB = {};

    --突袭战斗的站位 敌人随机从出生点中刷新
    if isRaid then
        local battleFormationId = monsterTeamsCfg["formation"]
        posInfos = StringUtil.ToStringArray_symbol_2(cfg_battleFormation[battleFormationId]["coordinate2"])

        if #posInfos < #idsB then
            Warning("Error in ABattleLogic:GetMonsterIdsAndPosInfos(). isRaid = true. monsterGrpId = ",monsterGrpId," #posInfos:",#posInfos," < #idsB:",#idsB);
        end

        for i = 1, #idsB, 1 do
            randomIndex = RandomUtil.Range(1,#posInfos);

            table.insert(posInfosB,posInfos[randomIndex]);
            table.remove(posInfos,randomIndex);
        end

    else
        local battleFormationId = monsterTeamsCfg["formation"]
        posInfos = StringUtil.ToStringArray_symbol_2(cfg_battleFormation[battleFormationId]["coordinate"])

        posInfosB = posInfos;
    end

    return idsB,posInfosB;
end

function ABattleLogic:HardCodeData()
    LGameData.Clear()
    --------------------------- Team A ---------------------------------
    -- local a1 = LLevelEntityData.new()
    -- a1.cardId = 11006 --胡八一
    -- a1.pos = VInt3.new(10783,-10510,16)
    -- a1.posRowIndex = 1
    -- a1.skillIds = {601,602,615,625,634,645,190011}
    -- LGameData.AddDataA(a1)

    -- local a2 = LLevelEntityData.new()
    -- a2.cardId = 11002 --了尘
    -- a2.pos = VInt3.new(10983,-10710,16)
    -- a2.posRowIndex = 1
    -- a2.skillIds = {201,202,214,225,235,244}
    -- LGameData.AddDataA(a2)

    local a3 = LLevelEntityData.new()
    a3.cardId = 11008 --shirley杨
    a3.pos = VInt3.new(10983,-10310,16)
    a3.posRowIndex = 2
    a3.skillIds = {801,835} --801,802,814,825,835,844,190011
    LGameData.AddDataA(a3)

    -- local a4 = LLevelEntityData.new()
    -- a4.cardId = 100000001 --主角
    -- a4.pos = VInt3.new(10583,-10710,16)
    -- a4.posRowIndex = 2
    -- a4.skillIds = {200001,200002,200015,200025,200035,210015,210025,210035}
    -- LGameData.AddDataA(a4)

    -- local a5 = LLevelEntityData.new()
    -- a5.cardId = 11110 --张赢川
    -- a5.pos = VInt3.new(10583,-10310,16)
    -- a5.posRowIndex = 2
    -- a5.skillIds = {1001,1002,1025} --1001,1002,1014,1025,1034,1044,190021
    -- LGameData.AddDataA(a5)

    --------------------------- Team B ---------------------------------
    -- local b1 = LLevelEntityData.new()
    -- b1.cardId = 1001
    -- b1.pos = VInt3.new(11283,-11062,16)
    -- b1.posRowIndex = 1
    -- b1.skillIds = {300101,300121} --300101,300111
    -- LGameData.AddDataB(b1)

    -- local b2 = LLevelEntityData.new()
    -- b2.cardId = 1002
    -- b2.pos = VInt3.new(11283,-10786,16)
    -- b2.posRowIndex = 1
    -- b2.skillIds = {300201} --300201,300211
    -- LGameData.AddDataB(b2)

    -- local b3 = LLevelEntityData.new()
    -- b3.cardId = 1003
    -- b3.pos = VInt3.new(11283,-10510,20)
    -- b3.posRowIndex = 2
    -- b3.skillIds = {300301,300311}
    -- LGameData.AddDataB(b3)

    -- local b4 = LLevelEntityData.new()
    -- b4.cardId = 100001
    -- b4.pos = VInt3.new(10283,-11062,20)
    -- b4.posRowIndex = 1
    -- b4.skillIds = {400101,400111,400121,400131}
    -- LGameData.AddDataB(b4)

    local b5 = LLevelEntityData.new()
    b5.cardId = 1004
    b5.pos = VInt3.new(10283,-10786,20)
    b5.posRowIndex = 2
    b5.skillIds = {300301} --300301,300311
    LGameData.AddDataB(b5)
    --------------------------- End ---------------------------------

    local osTime = 1579315088 --os.time();
    local randomseed = tostring(osTime):reverse():sub(1, 7)
    local mapId = 2
    local isRaid = true 
    LGameData.Initialize(mapId,randomseed,isRaid)

    return LGameData
end

function ABattleLogic:EndBattle(body)
    self.isInBattle = false;
    Entry:EndBattle(body.bWin);
    Entry:Dispose();
    self:BattleDispose(body.bWin)
end

--[[
    切回关卡场景
    战斗逻辑Dispose]]
function ABattleLogic:BattleDispose(bWin)
    self.battleMap:SetShouldBeVisible(true);
    local camera = UE4.ULuaCallCppFunctionLib.FindSceneActorByName("PlayerCamera" , self:GetWorld())
    if camera then
        local controller = UE4.UGameplayStatics.GetPlayerController(self:GetWorld(),0)
        controller:SetViewTargetWithBlend(camera)
    end

    if self.bTestBattle then
        --测试战斗结束
        self:sendNotification(PureMVCEvents.BattleEvent_BeginTest,{})
    else
        local copyLogic = BaseMain:Instance():getCurCopyLogic();
        if copyLogic then
            copyLogic:endCopyBattle(bWin);
        end
    end
end

function ABattleLogic:PlayCameraMoveSequence()
    if self.cameraSequence then
        if self.cameraSequence.SequencePlayer then
            self.cameraSequence.SequencePlayer:Play();

            self:ResetCameraMoveSequence();
        end
    end
end

function ABattleLogic:StopCameraMoveSequence()
    if self.cameraSequence then
        if self.cameraSequence.SequencePlayer then
            self.cameraSequence.SequencePlayer:Stop();

            self:ResetCameraMoveSequence();
        end
    end
end

function ABattleLogic:ResetCameraMoveSequence()
    self.cameraSequencePauseFlag = 0;
    self.cameraSequence.SequencePlayer:SetPlayRate(1);
end

function ABattleLogic:PauseCameraMoveSequence()
    self.cameraSequencePauseFlag = self.cameraSequencePauseFlag +1;
    if self.cameraSequencePauseFlag >0 and self.cameraSequence then
        if self.cameraSequence.SequencePlayer then
            self.cameraSequence.SequencePlayer:SetPlayRate(0);
        end
    end
end

function ABattleLogic:ResumeCameraMoveSequence()
    self.cameraSequencePauseFlag = self.cameraSequencePauseFlag -1;
    if self.cameraSequencePauseFlag <=0 and self.cameraSequence then
        if self.cameraSequence.SequencePlayer then
            self.cameraSequence.SequencePlayer:SetPlayRate(1);
        end
    end
end


--显示战斗跳字
function ABattleLogic:showBattleText(body)

    local pos = body.pos
    local battleType = body.battleType
    local str = body.str
    local dirX = body.dirX
    local bCrit = body.bCrit

    local act = ActorObjPoolMgr:GetInstance():PopObj("/Game/BluePrints/Battle/battleText/BP_BaseBattleTextActor",
                                        true,false,false,true);

    if act and act.showBattleText then
        act:K2_SetActorLocation(pos);
        act:showBattleText(str,battleType,dirX,bCrit);
    end
    table.insert(self.arrBattleActor,act);
end


function ABattleLogic:hideBattleText(battleAct)
    for key, value in pairs(self.arrBattleActor) do
        if value == battleAct then
            table.remove(self.arrBattleActor,key);
            ActorObjPoolMgr:GetInstance():PushObj(value)
            break;
        end
    end

    -- battleAct:K2_DestroyActor();
end

function ABattleLogic:hideAllBattleText()
    for key, value in pairs(self.arrBattleActor) do
        -- value:K2_DestroyActor();
        ActorObjPoolMgr:GetInstance():PushObj(value)
    end
    self.arrBattleActor = {};
end


function ABattleLogic:listNotificationInterests()
    return {PureMVCEvents.BattleEvent_Begin,
    PureMVCEvents.BattleEvent_End,
    PureMVCEvents.PMVCEvent_BattleLogic_ShowBattleText,
    PureMVCEvents.PMVCEvent_BattleLogic_HideAllBattleText,
    PureMVCEvents.PMVCEvent_BattleLogic_SetMapVisible,
    PureMVCEvents.BattleEvent_BeginTest}
end

function ABattleLogic:handleNotification(notification)

	local body = notification.body;
	local name = notification.name;

    if name == PureMVCEvents.BattleEvent_Begin then
        self:BeginBattle(body);
    elseif name == PureMVCEvents.BattleEvent_BeginTest then
        self:BeginBattle(body,true);
    elseif name == PureMVCEvents.BattleEvent_End then
        self:EndBattle(body)
    elseif name == PureMVCEvents.PMVCEvent_BattleLogic_ShowBattleText then
        self:showBattleText(body)
    elseif name == PureMVCEvents.PMVCEvent_BattleLogic_HideAllBattleText then
        self:hideAllBattleText();
    elseif name == PureMVCEvents.PMVCEvent_BattleLogic_SetMapVisible then
        self.battleMap:SetShouldBeVisible(body.bBattleMap);
        self.battleSequenceMap:SetShouldBeVisible(body.bBattleSequenceMap);
    end
end

testBody = {
    ["bIsRaid"] = false,
    ["iMonsterGrpId"] = 3,
    ["iFightMapId"] = 2,
    ["kPlayerInfo"] = {
        ["arrBuffList"] = {
        },
        ["iTeamType"] = 1,
        ["kAttrList"] = {
            [1] = 1000,
            [2] = 100,
            [3] = 1500,
            [4] = 0,
            [5] = 1600,
            [6] = 4,
            [7] = 999,
            [8] = 1548,
            [9] = 1500,
            [10] = 1000,
            [11] = 0,
        },
    },
    ["iRandomSeed"] = 816,
    ["arrCardInfo"] = {
        [1] = {
            ["arrBuffList"] = {
            },
            ["arrSkillList"] = {
                [1] = {
                    ["iSkillId"] = 645,
                    ["bIsActive"] = true,
                },
                [2] = {
                    ["iSkillId"] = 615,
                    ["bIsActive"] = true,
                },
                [3] = {
                    ["iSkillId"] = 190021,
                    ["bIsActive"] = true,
                },
                [4] = {
                    ["iSkillId"] = 634,
                    ["bIsActive"] = true,
                },
                [5] = {
                    ["iSkillId"] = 625,
                    ["bIsActive"] = true,
                },
            },
            ["iCardId"] = 11312,
            ["iSeat"] = 3,
            ["iCurHp"] = 56404,
            ["kAttrList"] = {
                [1] = 56404,
                [2] = 3013,
                [3] = 904,
                [11] = 0,
                [12] = 0,
                [13] = 0,
                [14] = 0,
                [15] = 0,
                [16] = 0,
                [64] = 0,
                [65] = 0,
                [66] = 0,
                [63] = 0,
                [70] = 0,
                [1031] = 0,
                [40] = 10000,
                [73] = 0,
                [1002] = 0,
                [1003] = 0,
                [9996] = 56404.0,
                [9997] = 3013.0,
                [9998] = 904.0,
                [9999] = 0,
                [62] = 0,
                [1001] = 0,
                [50] = 0,
                [1011] = 0,
                [20] = 0,
                [41] = 0,
                [71] = 0,
                [72] = 0,
                [1012] = 0,
                [51] = 0,
                [32] = 0,
                [33] = 0,
                [60] = 0,
                [61] = 0,
                [30] = 5000,
                [31] = 5000,
            },
        },
        [2] = {
            ["arrBuffList"] = {
            },
            ["arrSkillList"] = {
                [1] = {
                    ["iSkillId"] = 1044,
                    ["bIsActive"] = true,
                },
                [2] = {
                    ["iSkillId"] = 1014,
                    ["bIsActive"] = true,
                },
                [3] = {
                    ["iSkillId"] = 190021,
                    ["bIsActive"] = true,
                },
                [4] = {
                    ["iSkillId"] = 1034,
                    ["bIsActive"] = true,
                },
                [5] = {
                    ["iSkillId"] = 1025,
                    ["bIsActive"] = true,
                },
            },
            ["iCardId"] = 11313,
            ["iSeat"] = 5,
            ["iCurHp"] = 56387,
            ["kAttrList"] = {
                [1] = 56387,
                [2] = 3013,
                [3] = 904,
                [11] = 0,
                [12] = 0,
                [13] = 0,
                [14] = 0,
                [15] = 0,
                [16] = 0,
                [64] = 0,
                [65] = 0,
                [66] = 0,
                [63] = 0,
                [70] = 0,
                [1031] = 0,
                [40] = 10000,
                [73] = 0,
                [1002] = 0,
                [1003] = 0,
                [9996] = 56387.0,
                [9997] = 3013.0,
                [9998] = 904.0,
                [9999] = 0,
                [62] = 0,
                [1001] = 0,
                [50] = 0,
                [1011] = 0,
                [20] = 0,
                [41] = 0,
                [71] = 0,
                [72] = 0,
                [1012] = 0,
                [51] = 0,
                [32] = 0,
                [33] = 0,
                [60] = 0,
                [61] = 0,
                [30] = 5000,
                [31] = 5000,
            },
        },
        [3] = {
            ["arrBuffList"] = {
            },
            ["arrSkillList"] = {
            },
            ["iCardId"] = 100000001,
            ["iSeat"] = 1,
            ["iCurHp"] = 2046,
            ["kAttrList"] = {
                [1] = 2046,
                [2] = 95,
                [3] = 28,
                [11] = 0,
                [12] = 0,
                [13] = 0,
                [14] = 0,
                [15] = 0,
                [16] = 0,
                [64] = 0,
                [65] = 0,
                [66] = 0,
                [63] = 0,
                [70] = 0,
                [1031] = 0,
                [40] = 0,
                [73] = 0,
                [1002] = 1,
                [1003] = 1,
                [9996] = 2046.0,
                [9997] = 95.0,
                [9998] = 28.0,
                [9999] = 0,
                [62] = 0,
                [1001] = 1,
                [50] = 0,
                [1011] = 0,
                [20] = 0,
                [41] = 0,
                [71] = 0,
                [72] = 0,
                [1012] = 0,
                [51] = 0,
                [32] = 0,
                [33] = 0,
                [60] = 0,
                [61] = 0,
                [30] = 0,
                [31] = 0,
            },
        },
        [4] = {
            ["arrBuffList"] = {
            },
            ["arrSkillList"] = {
                [1] = {
                    ["iSkillId"] = 645,
                    ["bIsActive"] = true,
                },
                [2] = {
                    ["iSkillId"] = 615,
                    ["bIsActive"] = true,
                },
                [3] = {
                    ["iSkillId"] = 190011,
                    ["bIsActive"] = true,
                },
                [4] = {
                    ["iSkillId"] = 634,
                    ["bIsActive"] = true,
                },
                [5] = {
                    ["iSkillId"] = 625,
                    ["bIsActive"] = true,
                },
            },
            ["iCardId"] = 11310,
            ["iSeat"] = 4,
            ["iCurHp"] = 56404,
            ["kAttrList"] = {
                [1] = 56404,
                [2] = 3013,
                [3] = 904,
                [11] = 0,
                [12] = 0,
                [13] = 0,
                [14] = 0,
                [15] = 0,
                [16] = 0,
                [64] = 0,
                [65] = 0,
                [66] = 0,
                [63] = 0,
                [70] = 0,
                [1031] = 0,
                [40] = 10000,
                [73] = 0,
                [1002] = 0,
                [1003] = 0,
                [9996] = 56404.0,
                [9997] = 3013.0,
                [9998] = 904.0,
                [9999] = 0,
                [62] = 0,
                [1001] = 0,
                [50] = 0,
                [1011] = 0,
                [20] = 0,
                [41] = 0,
                [71] = 0,
                [72] = 0,
                [1012] = 0,
                [51] = 0,
                [32] = 0,
                [33] = 0,
                [60] = 0,
                [61] = 0,
                [30] = 5000,
                [31] = 5000,
            },
        },
        [5] = {
            ["arrBuffList"] = {
            },
            ["arrSkillList"] = {
                [1] = {
                    ["iSkillId"] = 645,
                    ["bIsActive"] = true,
                },
                [2] = {
                    ["iSkillId"] = 615,
                    ["bIsActive"] = true,
                },
                [3] = {
                    ["iSkillId"] = 190011,
                    ["bIsActive"] = true,
                },
                [4] = {
                    ["iSkillId"] = 634,
                    ["bIsActive"] = true,
                },
                [5] = {
                    ["iSkillId"] = 625,
                    ["bIsActive"] = true,
                },
            },
            ["iCardId"] = 11311,
            ["iSeat"] = 2,
            ["iCurHp"] = 75054,
            ["kAttrList"] = {
                [1] = 75054,
                [2] = 2013,
                [3] = 1204,
                [11] = 0,
                [12] = 0,
                [13] = 0,
                [14] = 0,
                [15] = 0,
                [16] = 0,
                [64] = 0,
                [65] = 0,
                [66] = 0,
                [63] = 0,
                [70] = 0,
                [1031] = 0,
                [40] = 10000,
                [73] = 0,
                [1002] = 0,
                [1003] = 0,
                [9996] = 75054.0,
                [9997] = 2013.0,
                [9998] = 1204.0,
                [9999] = 0,
                [62] = 0,
                [1001] = 0,
                [50] = 0,
                [1011] = 0,
                [20] = 0,
                [41] = 0,
                [71] = 0,
                [72] = 0,
                [1012] = 0,
                [51] = 0,
                [32] = 0,
                [33] = 0,
                [60] = 0,
                [61] = 0,
                [30] = 5000,
                [31] = 5000,
            },
        },
    },
} 

return ABattleLogic
