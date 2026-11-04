local SG = require(game:GetService("ReplicatedStorage").SceneGeneration.SG)
local DP = require(game:GetService("ReplicatedStorage").SceneGeneration.DP)
local Attributes = {WallColor="white",BalconyColor="dark",Curtains=true}
return {
	Attributes = Attributes,
	Schema = { WallColor = { shape = false }, BalconyColor = { shape = false }, Curtains = { shape = false } },
	OnGenerate = function(parameters, container)
		SG.into(container, function()
					local A=SG.attributes{WallColor="white",BalconyColor="dark",Curtains=true}
					SG.seat("Mori Store and Apartments",0,-80,0,function()
						SG.group("Convenience Store Shell",nil,function()
							SG.box(42,0.5,30,SG.pos(0,0.25,0),"concrete")
							SG.boxes{
								42,10,0.6,0,5.5,-15,A.WallColor,
								0.6,10,30,-21,5.5,0,A.WallColor,
								0.6,10,30,21,5.5,0,A.WallColor,
								42,0.6,30,0,10.7,0,"white"
							}
							for _,x in ipairs({-20,-4.5,4.5,20}) do
								SG.box(0.4,8,0.4,SG.pos(x,4.5,15),"dark")
							end
							for _,x in ipairs({-12.2,12.2}) do
								SG.box(15,7.5,0.18,SG.pos(x,4.4,15),"glass")
								SG.box(15,0.35,0.5,SG.pos(x,0.7,15),"dark")
							end
							SG.box(42,1.5,0.65,SG.pos(0,9.4,15),"teal")
							SG.box(42,0.22,0.7,SG.pos(0,8.55,15),"lime")
							SG.box(42,0.22,0.7,SG.pos(0,10.25,15),"orange")
						end)
						SG.group("Open Sliding Double Entrance",nil,function()
							for _,x in ipairs({-5.4,5.4}) do
								SG.box(3.5,7.7,0.18,SG.pos(x,4.35,15.15),"glass")
								for _,dx in ipairs({-1.75,1.75}) do
									SG.box(0.12,7.7,0.25,SG.pos(x+dx,4.35,15.15),"metal")
								end
								SG.box(0.1,1.5,0.3,SG.pos(x,4,15.35),"metal")
							end
							SG.box(9,0.4,0.6,SG.pos(0,8.4,15),"dark")
							SG.box(8,0.06,0.2,SG.pos(0,0.56,15),"metal")
						end)
						SG.group("Illuminated Store Fascia",nil,function()
							SG.style("cream","Neon")
							local panel=SG.box(18,2.1,0.25,SG.cframe(0,9.55,15.5,0,180,0),"cream")
							local art=DP.decal("rbxassetid://105862367698424")
							DP.applyDecalOnFace(panel,panel.CFrame.LookVector,art)
							SG.light("surface",SG.cframe(0,9.5,15.8,0,180,0),"cream",12,1.4)
						end)
						SG.group("Bright Store Ceiling Lighting",nil,function()
							SG.style("cream","Neon")
							for _,x in ipairs({-12,0,12}) do
								SG.box(7,0.12,1,SG.pos(x,10.25,0),"cream")
								SG.light("point",SG.pos(x,9.7,0),"cream",18,1.2)
							end
						end)
						SG.group("Checkout Counter",SG.pos(12,0.5,10),function()
							SG.box(6,3,2.5,SG.pos(0,1.5,0),"teal")
							SG.box(6.3,0.2,2.8,SG.pos(0,3.1,0),"white")
							SG.box(1.4,0.2,1,SG.pos(0,3.3,0),"dark")
							SG.box(1.2,0.8,0.12,SG.cframe(0,3.8,0,0,180,0),"ink")
						end)
						SG.group("Rear Refrigerated Drinks Cases",nil,function()
							for _,x in ipairs({-13,-6,1,8}) do
								SG.group("Glass Refrigerator "..x,SG.pos(x,0.5,-12.8),function()
									SG.box(6,7.8,2.5,SG.pos(0,3.9,0),"dark")
									SG.box(5.5,7.1,0.12,SG.pos(0,3.9,1.3),"glass")
									for row=1,4 do
										SG.box(5.4,0.12,1.8,SG.pos(0,row*1.5,0.6),"white")
										for col=1,7 do
											SG.disc(0.22,0.8,SG.pos(-2.5+col*0.65,row*1.5+0.45,0.65),"blue")
										end
									end
									SG.box(0.1,1.4,0.2,SG.pos(2.4,4,1.4),"metal")
								end)
							end
						end)
						for floor=1,3 do
							local y=11+(floor-1)*10
							SG.group("Apartment Level "..floor,nil,function()
								SG.box(42,0.4,30,SG.pos(0,y+0.2,0),"concrete")
								SG.box(42,1.8,30,SG.pos(0,y+1.3,0),A.WallColor)
								SG.box(42,2.3,30,SG.pos(0,y+8.85,0),A.WallColor)
								for _,x in ipairs({-21,-7,7,21}) do
									SG.box(0.65,6.2,30,SG.pos(x,y+4.8,0),A.WallColor)
								end
								SG.box(42,6.2,0.4,SG.pos(0,y+4.8,-15),A.WallColor)
								for _,x in ipairs({-14,0,14}) do
									SG.group("Balcony Apartment "..x,nil,function()
										SG.box(11.6,5.6,0.18,SG.pos(x,y+4.7,15),"glass")
										if A.Curtains then
											for _,dx in ipairs({-4.1,4.1}) do
												SG.box(2.9,5.2,0.15,SG.pos(x+dx,y+4.6,14.5),"curtain")
												for p=-1,1 do
													SG.box(0.12,5.2,0.12,SG.pos(x+dx+p*0.65,y+4.6,14.65),"cream")
												end
											end
										end
										SG.box(0.2,5.6,0.25,SG.pos(x,y+4.7,15.2),"dark")
										SG.box(12.5,0.4,3.4,SG.pos(x,y+0.4,16.7),"concrete")
										for _,z in ipairs({15.2,18.3}) do
											SG.box(12.5,0.14,0.14,SG.pos(x,y+3.4,z),A.BalconyColor)
										end
										for p=0,10 do
											SG.box(0.1,2.9,0.1,SG.pos(x-6+p*1.2,y+1.9,18.3),A.BalconyColor)
										end
										for _,dx in ipairs({-6.1,6.1}) do
											SG.box(0.13,2.9,3.2,SG.pos(x+dx,y+1.9,16.7),A.BalconyColor)
										end
										SG.group("Balcony Air Conditioner",SG.pos(x+4.4,y+0.6,16.4),function()
											SG.box(2.2,1.6,1,SG.pos(0,0.8,0),"white")
											SG.disc(0.58,0.08,SG.cframe(0,0.8,0.55,90,0,0),"metal")
											for p=-2,2 do
												SG.box(1.1,0.07,0.08,SG.pos(0,0.8+p*0.2,0.64),"dark")
											end
										end)
									end)
								end
								SG.box(0.1,6.5,3.4,SG.pos(21.4,y+3.65,-10),"teal")
							end)
						end
						SG.group("Flat Roof and Safety Rail",nil,function()
							SG.box(42,0.5,30,SG.pos(0,41.25,0),"concrete")
							for _,z in ipairs({-14.8,14.8}) do
								SG.box(42,0.12,0.12,SG.pos(0,44,z),"dark")
								for x=-21,21,3 do SG.box(0.12,2.5,0.12,SG.pos(x,42.75,z),"dark") end
							end
							for _,x in ipairs({-20.8,20.8}) do
								SG.box(0.12,0.12,30,SG.pos(x,44,0),"dark")
								for z=-15,15,3 do
									if x<0 or z>-6 then
										SG.box(0.12,2.5,0.12,SG.pos(x,42.75,z),"dark")
									end
								end
							end
						end)
						SG.group("Roof Water Tank",SG.pos(-12,41.5,-8),function()
							SG.box(6,0.5,6,SG.pos(0,0.25,0),"dark")
							SG.disc(2.3,4.8,SG.pos(0,2.9,0),"metal")
							SG.frustum(2.3,0.8,0.7,12,SG.pos(0,5.65,0),"metal")
						end)
						SG.group("Solar Array",nil,function()
							for x=0,12,6 do
								SG.box(5,0.3,7,SG.cframe(x,42.4,-5,-12,0,0),"blue")
								SG.box(0.2,1,6,SG.pos(x,42,-5),"metal")
							end
						end)
						SG.group("Roof Antenna",nil,function()
							SG.segment(17,41.5,-11,17,49,-11,0.15,"metal")
							for y=46,48,1 do SG.segment(15,y,-11,19,y,-11,0.1,"metal") end
						end)
						SG.group("Window Promotion Poster",nil,function()
							local panel=SG.box(3.2,4.8,0.05,SG.cframe(-14,4.2,15.2,0,180,0),"cream")
							local art=DP.decal("rbxassetid://94794852545308")
							DP.applyDecalOnFace(panel,panel.CFrame.LookVector,art)
						end)
					end,{pad=true,footprint={42,30}})

		end, parameters.Attributes, parameters.Size)
	end,
}
