local hideTable = import('/lua/sim/BuffDefinitions.lua').HideTable

local oldUnit = Unit
Unit = Class(oldUnit) {

---------------
----VETERANCY------
---------------

    OnCreate = function(self)
        oldUnit.OnCreate(self)

        --Get unit blueprint for setting variables
        local bp = GetBlueprint(self)
        -- Define Economic modifications
        local bpEcon = bp.Economy

        --this bit added in eq, its lets us have a dynamic cost and change it on the fly if we need to.
        self.BuildCostM = bpEcon.BuildCostMass
        self.BuildCostE = bpEcon.BuildCostEnergy
        self.BuildT = bpEcon.BuildTime
    end,

    OnKilled = function(self, instigator, type, overkillRatio)
        self.Dead = true
        self:HandleStorage()        --Ithilis add only this
        oldUnit.OnKilled(self, instigator, type, overkillRatio)
    end,
    
    -- Veterancy can't be 'Undone', so we heal the unit directly, one-off, rather than using a buff. Much more flexible.
    -- Or we would if healing wasnt a dumb idea, so now its just doing nothing.
    DoVeterancyHealing = function(self, level)
    end,

    CreateVeterancyBuffs = function(self, level)
        local healthBuffName = 'VeterancyMaxHealth' .. level -- Currently there is no difference between units, therefore no need for unique buffs
        local regenBuffName = self:GetUnitId() .. 'VeterancyRegen' .. level -- Generate a buff based on the unitId - eg. uel0001VeterancyRegen3

        if not Buffs[regenBuffName] then
            -- Maps self.techCategory to a number so we can do math on it for naval units
            local techLevels = {
                TECH1 = 1,
                TECH2 = 2,
                TECH3 = 3,
                COMMAND = 3,
                SUBCOMMANDER = 4,
                EXPERIMENTAL = 5,
            }
            
            local techLevel = techLevels[self.techCategory] or 1
            
            -- Treat naval units as one level higher
            if techLevel < 4 and EntityCategoryContains(categories.NAVAL, self) then
                techLevel = techLevel + 1
            end
            
            -- Regen values by tech level and veterancy level
            -- EQ: we reorder and change the sacu/t4 ones a little so ships get the sacu and not exp values
            local regenBuffs = {
                {1,  2,  3,  4,  5}, -- T1
                {3,  6,  9,  12, 15}, -- T2
                {6,  12, 18, 24, 30}, -- T3 / ACU
                {9,  18, 27, 36, 45}, -- SACU
                {12, 24, 36, 48, 60}, -- Experimental
            }
        
            BuffBlueprint {
                Name = regenBuffName,
                DisplayName = regenBuffName,
                BuffType = 'VeterancyRegen',
                Stacks = 'REPLACE',
                Duration = -1,
                Affects = {
                    Regen = {
                        Add = regenBuffs[techLevel][level],
                    },
                },
            }
        end
        
        return {regenBuffName, healthBuffName}
    end,
    
    -- Returns true if a unit can gain veterancy (Has a weapon)
    ShouldUseVetSystem = function(self)
        local weps = self:GetBlueprint().Weapon

        -- Bail if we don't have any weapons
        if not weps[1] then
            return false
        end

        -- EQ: Add manual exceptions table for suicide units and things like tmd
        if hideTable[self:GetUnitId()] then return false end
        
        -- Find a weapon which is not a DeathWeapon
        for index, wep in weps do
            if wep.Label ~= 'DeathWeapon' then
                return true
            end
        end

        -- We only have a DeathWeapon. Bail.
        return false
    end,
-------------------------------------------------------------------------------------------
-- DAMAGE
-------------------------------------------------------------------------------------------
    DoDeathWeapon = function(self)
        if self:IsBeingBuilt() then return end
        local bp = self:GetBlueprint()
        for k, v in bp.Weapon do
            if(v.Label == 'DeathWeapon') then
            if self.NewDeathDamage then
                --added a modifier to our deathweapon damage, if it was put into the unit script somewhere
                -- it needs to be dropped into the unit table since our weapon tables seem to be cleared on death,
                -- and this code fired based on the blueprint values, so we intercept them here
                --WARN('exploding with damage: ' .. self.NewDeathDamage)
                v.Damage = self.NewDeathDamage
            end
            
            
                if v.FireOnDeath == true then
                    self:SetWeaponEnabledByLabel('DeathWeapon', true)
                    self:GetWeaponByLabel('DeathWeapon'):Fire()
                else
                    self:ForkThread(self.DeathWeaponDamageThread, v.DamageRadius, v.Damage, v.DamageType, v.DamageFriendly)
                end
                break
            end
        end
    end,

-----
-- Water Guard: Underwater units take less damage from above water splash damage 
-- By Balthazar
-----
    
    OnDamage = function(self, instigator, amount, vector, damageType, ...)
        if damageType == 'NormalAboveWater' and (self:GetCurrentLayer() == 'Sub' or self:GetCurrentLayer() == 'Seabed') then
            local bp = self:GetBlueprint()
            local myheight = bp.Physics.MeshExtentsY or bp.SizeY or 0
            local depth = math.abs(vector[2]) - myheight
            --WARN(depth) -- use this to tune the cutoff depth for damage
            if depth > 1 then return --units deep underwater take 0 damage
            else
                oldUnit.OnDamage(self, instigator, amount, vector, damageType, unpack(arg))
                --the unpack here is to maintain compatibility incase some new arg is added
            end
        else
            -- units with their head poking above or only thin layer of water take full damage
            oldUnit.OnDamage(self, instigator, amount, vector, damageType, unpack(arg))
        end
    end, 

---------------    
----RECLAIM------
---------------

 -- the only thing we change is the mass value on the seabed, which should also be 50% of the max and not 100%
     CreateWreckageProp = function(self, overkillRatio)
        local bp = self:GetBlueprint()

        local wreck = bp.Wreckage.Blueprint
        if not wreck then
            return nil
        end

        local mass = bp.Economy.BuildCostMass * (bp.Wreckage.MassMult or 0)
        local energy = bp.Economy.BuildCostEnergy * (bp.Wreckage.EnergyMult or 0)
        local time = (bp.Wreckage.ReclaimTimeMultiplier or 1)
        local pos = self:GetPosition()
        local layer = self:GetCurrentLayer()

        -- Reduce the mass value of submerged wrecks
        if layer == 'Water' or layer == 'Sub' or layer == 'Seabed' then --we just add the seabed bit in here and thats it.
            mass = mass * 0.5
            energy = energy * 0.5
        end

        local halfBuilt = self:GetFractionComplete() < 1

        -- Make sure air / naval wrecks stick to ground / seabottom, unless they're in a factory.
        if not halfBuilt and (layer == 'Air' or EntityCategoryContains(categories.NAVAL - categories.STRUCTURE, self)) then
            pos[2] = GetTerrainHeight(pos[1], pos[3]) + GetTerrainTypeOffset(pos[1], pos[3])
        end

        local overkillMultiplier = 1 - (overkillRatio or 1)
        mass = mass * overkillMultiplier * self:GetFractionComplete()
        energy = energy * overkillMultiplier * self:GetFractionComplete()
        time = time * overkillMultiplier

        -- Now we adjust the global multiplier. This is used for balance purposes to adjust global reclaim rate.
        local time  = time * 2

        local prop = Wreckage.CreateWreckage(bp, pos, self:GetOrientation(), mass, energy, time)

        -- Attempt to copy our animation pose to the prop. Only works if
        -- the mesh and skeletons are the same, but will not produce an error if not.
        if (layer ~= 'Air' and self.PlayDeathAnimation) or (layer == "Air" and halfBuilt) then
            TryCopyPose(self, prop, true)
        end

        -- Create some ambient wreckage smoke
        explosion.CreateWreckageEffects(self, prop)

        return prop
    end,

-----
--Mass storages lose the mass contained in them when they die  
-- code is from there  https://github.com/FAForever/fa/pull/581/files
-----

    HandleStorage = function(self, to_army)
        if EntityCategoryContains(categories.MOBILE, self) then
            return -- Exclude ACU / SCU / sparky
        end

        local bp = self:GetBlueprint()
        local brain = GetArmyBrain(self:GetArmy())
        for _, t in {'Mass', 'Energy'} do
            if bp.Economy['Storage' .. t] then
                local type = string.upper(t)
                local amount = bp.Economy['Storage' .. t] * brain:GetEconomyStoredRatio(type)

                brain:TakeResource(type, amount)
                if to_army then
                    local to = GetArmyBrain(to_army)
                    to:GiveResource(type, amount)
                end
            end
        end
    end,

----------------------------------------------------------------------------------------------
-- CONSTRUCTING - BUILDING - REPAIR
----------------------------------------------------------------------------------------------

--advanced rebuild with re-assist
    OnStopBuild = function(self, built)
        --we catch this flag left by the wreckage, letting us know if we need to re-assist it after rebuilding it.
        if self.ShouldAssist == true then
            self.ShouldAssist = false --flag the unit as not rebuilding anything.
            IssueGuard({self}, built)
        end
        oldUnit.OnStopBuild(self, built)
    end,

    OnFailedToBuild = function(self)
        self.ShouldAssist = false --flag the unit as not rebuilding anything.
        oldUnit.OnFailedToBuild(self)
    end,
    
--global sacrifice system adjustment, the order itself is engine-side so we just pick up the pieces
    OnStartSacrifice = function(self, target_unit)
        EffectUtilities.PlaySacrificingEffects(self,target_unit)
        local bp = self:GetBlueprint().Economy
        local donatemass = bp.BuildCostMass*bp.SacrificeMassMult
        local donateenergy = bp.BuildCostEnergy*bp.SacrificeEnergyMult
        
        --uncomment the warnings to help understand the maths behind the sacrifice system and how we compute the wreck value
        
        --WARN(donatemass .. ' mass should be donated')
        --WARN(donateenergy .. ' energy should be donated')
        
        local tgbp = target_unit:GetBlueprint().Economy
        
        local OwnMER = donatemass/donateenergy
        local TargetMER = tgbp.BuildCostMass/tgbp.BuildCostEnergy
        
        --WARN(OwnMER .. ' own mass/energy ratio')
        --WARN(TargetMER .. ' target mass/energy ratio')
        
        local MDM = TargetMER/OwnMER
        self.ActMassDonation = math.min(donatemass*MDM, donatemass)
        
        --WARN(MDM .. ' mass donation multiplier; ' .. self.ActMassDonation .. ' mass actually donated')
        --WARN(donatemass - donatemass*MDM .. 'mass should be refunded')
        
        --this is how much we should be sacrificing
        self.RefundAmount = math.max((donatemass - donatemass*MDM), 0) --in case the MDM is above 1, we should not make mass out of thin air.
        
        
        
        --incase our project has less mass needed to finish it that we are about to donate to it.
        local buildProjRemain = (1 - target_unit:GetFractionComplete())*tgbp.BuildCostMass
        
        --WARN('unit fraction completion: ' .. target_unit:GetFractionComplete())
        --WARN('mass needed to complete the project: ' .. buildProjRemain)
        
        
        --because we cant just use GetFractionComplete in OnStopSacrifice we have to track sacrifices on the target unit
        if not target_unit.MassToBeSacrificed then
            target_unit.MassToBeSacrificed = 0
        end
        
        --WARN('mass about to be donated: ' .. target_unit.MassToBeSacrificed)
        
        --we refund the mass if our unit is about to be finished. we dont refund it if its used to repair a complete unit.
        if self.ActMassDonation > (buildProjRemain - target_unit.MassToBeSacrificed) and target_unit:GetFractionComplete() ~= 1 then
            self.RefundAmount = donatemass - math.max((buildProjRemain - target_unit.MassToBeSacrificed), 0)
            --WARN('refund amount: ' .. self.RefundAmount)
            --WARN('mass donation with refund into account: ' .. math.max((buildProjRemain - target_unit.MassToBeSacrificed), 0))
        end
        
        --similar case as above, we refund if were trying to repair something thats already nearly full hp
        if target_unit:GetFractionComplete() == 1 then
            local repairProjRemain = (1 - (target_unit:GetHealth()/target_unit:GetMaxHealth()))*tgbp.BuildCostMass
            
            self.RefundAmount = donatemass - math.max((repairProjRemain - target_unit.MassToBeSacrificed), 0)
            --WARN('refund amount: ' .. self.RefundAmount)
            --WARN('mass donation with refund into account: ' .. math.max((buildProjRemain - target_unit.MassToBeSacrificed), 0))
        end
        
        
        target_unit.MassToBeSacrificed = target_unit.MassToBeSacrificed + self.ActMassDonation
    end,
    
    OnStopSacrifice = function(self, target_unit) --we will refund the unused mass by placing it in a wreck
        if self.RefundAmount >= 1 then
            --the /0.9 is there since our wreck is at 90% hp of the unit and so it only contains 90% of the mass it should.
            self:CreateSacrificeWreckageProp(self.RefundAmount/0.9)
        end
        --after we sacrifce ourselved we remove our mass from the list.
        target_unit.MassToBeSacrificed = math.max((target_unit.MassToBeSacrificed - self.ActMassDonation), 0)
        EffectUtilities.PlaySacrificeEffects(self,target_unit)
        self:SetDeathWeaponEnabled(false)
        self:Destroy() -- commenting this doesn't even stop it from disappearing, must be engine things
    end,
    
    CreateSacrificeWreckageProp = function( self, refundamount )
        local bp = self:GetBlueprint()

        local wreck = bp.Wreckage.Blueprint

        if not wreck then
            return nil
        end

        local mass = refundamount
        local energy = 0
        local time = (bp.Wreckage.ReclaimTimeMultiplier or 1)
        local pos = self:GetPosition()
        local layer = self:GetCurrentLayer()
        
        local prop = Wreckage.CreateWreckage(bp, pos, self:GetOrientation(), mass, energy, time)
        
        -- if (layer == 'Water') or (layer == "Sub") then
            -- WARN('trying to sink')
        -- end
        --FIXME: make the wreck sink, or do something about it appearing on the sea surface and then not doinganything

        -- Attempt to copy our animation pose to the prop. Only works if
        -- the mesh and skeletons are the same, but will not produce an error if not.
        if (layer ~= 'Air' and self.PlayDeathAnimation) then
            TryCopyPose(self, prop, true)
        end
        
        return prop
    end,
    
-------------------------------------------------------------------------------------------
-- LAYER EVENTS
-------------------------------------------------------------------------------------------

--here we let all units have proper watervision radii. helps with units shooting each other form the shore.
--we dont hook since normal faf has a vision disable code on amphibious units. bleh.
    OnLayerChange = function(self, new, old)
        -- Bail out early if dead. The engine calls this function AFTER entity:Destroy() has killed
        -- the C object. Any functions down this line which expect a live C object (self:CreateAnimator())
        -- for example, will throw an error.
        if self.Dead then return end

        for i = 1, self:GetWeaponCount() do
            self:GetWeapon(i):SetValidTargetsForCurrentLayer(new)
        end

        -- All units want normal vision!
        if old == 'None' then
            self:EnableIntel('Vision')
            self:EnableIntel('WaterVision')
        end
        
        --EQ: Units on land want a smaller watervision than units on water?
        --[[
        if (old == 'Seabed' or old == 'Water' or old == 'Sub' or old == 'None') and new == 'Land' then
            self:EnableIntel('WaterVision')
        elseif (old == 'Land' or old == 'None') and (new == 'Seabed' or new == 'Water' or new == 'Sub') then
            self:EnableIntel('WaterVision')
        end
        --]]

        if new == 'Land' then
            self:PlayUnitSound('TransitionLand')
            self:PlayUnitAmbientSound('AmbientMoveLand')
        elseif new == 'Water' or new == 'Seabed' then
            self:PlayUnitSound('TransitionWater')
            self:PlayUnitAmbientSound('AmbientMoveWater')
        elseif new == 'Sub' then
            self:PlayUnitAmbientSound('AmbientMoveSub')
        end

        local bpTable = self:GetBlueprint().Display.MovementEffects
        if not self.Footfalls and bpTable[new].Footfall then
            self.Footfalls = self:CreateFootFallManipulators(bpTable[new].Footfall)
        end
        self:CreateLayerChangeEffects(new, old)

        -- Trigger the re-worded stuff that used to be inherited, no longer because of the engine bug above.
        if self.LayerChangeTrigger then
            self:LayerChangeTrigger(new, old)
        end
    end,
    
-------------------------------------------------------------------------------------------
-- BUFFS
-------------------------------------------------------------------------------------------
--there was some fucked up changes to do with stun mechanics so we need to hook these to fix them
--no hardcoding to exclude air units please
--spheres make 500 times less sense than capped cylinders in supcom. ever heard of terrain?
    AddBuff = function(self, buffTable, PosEntity)
        local bt = buffTable.BuffType
        if not bt then
            error('*ERROR: Tried to add a unit buff in unit.lua but got no buff table.  Wierd.', 1)
            return
        end

        -- When adding debuffs we have to make sure that we check for permissions
        local category = buffTable.TargetAllow and ParseEntityCategory(buffTable.TargetAllow) or categories.ALLUNITS
        if buffTable.TargetDisallow then
            category = category - ParseEntityCategory(buffTable.TargetDisallow)
        end

        if bt == 'STUN' then
            local targets
            if buffTable.Radius and buffTable.Radius > 0 then
                -- If the radius is bigger than 0 then we will use the unit as the center of the stun blast
                targets = utilities.GetTrueEnemyUnitsInCylinder(self, PosEntity or self:GetPosition(), buffTable.Radius, buffTable.Height, category)
            else
                -- The buff will be applied to the unit only
                if EntityCategoryContains(category, self) then
                    targets = {self}
                end
            end
            for _, target in targets or {} do
                -- Exclude things currently flying around if we have a flag
                if not (buffTable.ExcludeAirLayer and target:GetCurrentLayer() == 'Air') then
                    target:SetStunned(buffTable.Duration or 1)
                end
            end
        elseif bt == 'MAXHEALTH' then
            self:SetMaxHealth(self:GetMaxHealth() + (buffTable.Value or 0))
        elseif bt == 'HEALTH' then
            self:SetHealth(self, self:GetHealth() + (buffTable.Value or 0))
        elseif bt == 'SPEEDMULT' then
            self:SetSpeedMult(buffTable.Value or 0)
        elseif bt == 'MAXFUEL' then
            self:SetFuelUseTime(buffTable.Value or 0)
        elseif bt == 'FUELRATIO' then
            self:SetFuelRatio(buffTable.Value or 0)
        elseif bt == 'HEALTHREGENRATE' then
            self:SetRegenRate(buffTable.Value or 0)
        end
    end,
    
}
