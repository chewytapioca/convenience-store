local SG = require(game:GetService("ReplicatedStorage").SceneGeneration.SG)
local Attributes = {RailColor="dark",StepMaterial="Concrete"}
return {
	Attributes = Attributes,
	Schema = { RailColor = { shape = false }, StepMaterial = { shape = false } },
	OnGenerate = function(parameters, container)
		SG.into(container, function()
					local A=SG.attributes{RailColor="dark",StepMaterial="Concrete"}
					SG.style("concrete",A.StepMaterial)
					SG.group("Eastern Switchback Staircase",nil,function()
						local base=SG.ground(27,-88) or 0
						for level=0,3 do
							local bottom=base
							local rise=11
							if level>0 then bottom=base+11+(level-1)*10 rise=10 end
							for flight=1,2 do
								local x=24
								if flight==2 then x=30 end
								local startY=bottom+(flight-1)*rise/2
								SG.group("Stair Flight "..level.."-"..flight,nil,function()
									for step=1,20 do
										local z=-88+(step-0.5)*0.5
										if flight==2 then z=-78-(step-0.5)*0.5 end
										local top=startY+step*rise/40
										SG.box(5,0.28,0.55,SG.pos(x,top-0.14,z),"concrete")
										if step%4==0 then
											for _,dx in ipairs({-2.4,2.4}) do
												SG.box(0.1,3,0.1,SG.pos(x+dx,top+1.5,z),A.RailColor)
											end
										end
									end
									local za=-88 local zb=-78
									if flight==2 then za=-78 zb=-88 end
									for _,dx in ipairs({-2.4,2.4}) do
										SG.segment(x+dx,startY+3,za,x+dx,startY+rise/2+3,zb,0.12,A.RailColor)
										SG.segment(x+dx,startY-0.35,za,x+dx,startY+rise/2-0.35,zb,0.25,"metal")
									end
								end)
							end
							SG.group("Stair Landings "..level,nil,function()
								SG.box(11,0.3,4,SG.pos(27,bottom+rise/2-0.15,-76),"concrete")
								SG.box(12,0.3,4,SG.pos(27,bottom+rise-0.15,-90),"concrete")
								SG.box(11,0.12,0.12,SG.pos(27,bottom+rise/2+3,-74),"dark")
								SG.box(12,0.12,0.12,SG.pos(27,bottom+rise+3,-92),"dark")
								for x=22,32,2 do
									SG.box(0.12,3,0.12,SG.pos(x,bottom+rise/2+1.5,-74),"dark")
									SG.box(0.12,3,0.12,SG.pos(x,bottom+rise+1.5,-92),"dark")
								end
							end)
						end
					end)

		end, parameters.Attributes, parameters.Size)
	end,
}
