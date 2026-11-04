local SG = require(game:GetService("ReplicatedStorage").SceneGeneration.SG)
local Attributes = {SidewalkMaterial="Concrete",StreetWidth=12}
return {
	Attributes = Attributes,
	Schema = { SidewalkMaterial = { shape = false }, StreetWidth = { shape = false } },
	OnGenerate = function(parameters, container)
		SG.into(container, function()
					local A=SG.attributes{SidewalkMaterial="Concrete",StreetWidth=12}
					SG.group("Two Way Neighborhood Street",nil,function()
						local streetTop=SG.road({-35,0,-47,35,0,-47},A.StreetWidth,"road",{shoulder=0,depth=3})
						local h=streetTop[2]
						for x=-30,30,12 do
							SG.box(6,0.04,0.18,SG.pos(x,h+0.15,-47),"cream")
						end
					end)
					SG.group("Storefront Pedestrian Forecourt",nil,function()
						SG.style("concrete",A.SidewalkMaterial)
						SG.road({-35,0,-59,35,0,-59},10,"concrete",{shoulder=0,depth=3})
						SG.road({0,0,-59,0,0,-64},14,"concrete",{shoulder=0,depth=3})
						SG.road({27,0,-59,27,0,-72},12,"concrete",{shoulder=0,depth=3})
					end)

		end, parameters.Attributes, parameters.Size)
	end,
}
