local SG = require(game:GetService("ReplicatedStorage").SceneGeneration.SG)
local Attributes = {ShelfCount=4,StockColor="orange"}
return {
	Attributes = Attributes,
	Schema = { ShelfCount = { shape = false }, StockColor = { shape = false } },
	OnGenerate = function(parameters, container)
		SG.into(container, function()
					local A=SG.attributes{ShelfCount=4,StockColor="orange"}
					local s=SG.size(Vector3.new(4,6,2))
					SG.boxes{
						0.18,s.Y,s.Z,-s.X/2,s.Y/2,0,"white",
						0.18,s.Y,s.Z,s.X/2,s.Y/2,0,"white",
						s.X,0.2,s.Z,0,0.1,0,"white"
					}
					for level=1,A.ShelfCount do
						local y=0.4+(level-1)*(s.Y-1)/A.ShelfCount
						SG.box(s.X,0.13,s.Z,SG.pos(0,y,0),"white")
						for col=1,5 do
							local x=-s.X/2+col*s.X/6
							SG.box(0.5,0.8,0.45,SG.pos(x,y+0.47,-0.55),A.StockColor)
							SG.box(0.4,0.16,0.46,SG.pos(x,y+0.75,-0.56),"cream")
							SG.box(0.5,0.75,0.45,SG.pos(x,y+0.44,0.55),"teal")
						end
						SG.box(s.X,0.18,0.06,SG.pos(0,y+0.1,-s.Z/2-0.03),"lime")
					end

		end, parameters.Attributes, parameters.Size)
	end,
}
