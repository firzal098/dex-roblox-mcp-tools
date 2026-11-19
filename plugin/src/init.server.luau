--[[
    Roblox MCP Bridge Plugin
    
    Connects Roblox Studio to the FastMCP server via WebSocket for instant
    bidirectional communication. Enables AI agents to inspect the game tree,
    read properties via ReflectionService, and query CollectionService tags.
    
    WebSocket endpoint: ws://127.0.0.1:8000
]]

------------------------------------------------------------------------
-- Services
------------------------------------------------------------------------
local HttpService = game:GetService("HttpService")
local CollectionService = game:GetService("CollectionService")
local ReflectionService = game:GetService("ReflectionService")
local RunService = game:GetService("RunService")
local ChangeHistoryService = game:GetService("ChangeHistoryService")
local LogService = game:GetService("LogService")
local Selection = game:GetService("Selection")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local VirtualInputManager = nil
pcall(function()
	VirtualInputManager = game:GetService("VirtualInputManager")
end)

local function getContextRole()
	if RunService:IsEdit() then
		return "edit"
	elseif RunService:IsServer() then
		return "server"
	elseif RunService:IsClient() then
		return "client"
	end
	return "unknown"
end

------------------------------------------------------------------------
-- Configuration
------------------------------------------------------------------------
local WS_URL = "ws://127.0.0.1:8000"
local RECONNECT_DELAY = 3 -- seconds between reconnection attempts
local MAX_CHILDREN_DEFAULT = 2000
local MAX_DESCENDANTS_DEFAULT = 5000

------------------------------------------------------------------------
-- State
------------------------------------------------------------------------
local pluginActive = false
local wsClient = nil
local isConnected = false
local isConnecting = false
local lastLoggedStatus = nil
local connectionAttemptTime = 0
local toolbar = plugin:CreateToolbar("MCP Bridge")
local toggleButton = toolbar:CreateButton("MCP Bridge", "Connect/Disconnect MCP Bridge", "rbxassetid://6031075938")

------------------------------------------------------------------------
-- Utility: Serialize Roblox values to JSON-safe types
------------------------------------------------------------------------
local function serializeValue(value)
	local t = typeof(value)

	if t == "string" or t == "number" or t == "boolean" then
		return value
	elseif t == "nil" then
		return nil  -- will be omitted from JSON
	elseif t == "Instance" then
		return { _type = "Instance", ClassName = value.ClassName, Name = value.Name, Path = value:GetFullName() }
	elseif t == "Vector3" then
		return { _type = "Vector3", X = value.X, Y = value.Y, Z = value.Z }
	elseif t == "Vector2" then
		return { _type = "Vector2", X = value.X, Y = value.Y }
	elseif t == "CFrame" then
		local pos = value.Position
		local rx, ry, rz = value:ToEulerAnglesXYZ()
		return { _type = "CFrame", Position = { X = pos.X, Y = pos.Y, Z = pos.Z }, Rotation = { X = math.deg(rx), Y = math.deg(ry), Z = math.deg(rz) } }
	elseif t == "Color3" then
		return { _type = "Color3", R = math.floor(value.R * 255), G = math.floor(value.G * 255), B = math.floor(value.B * 255) }
	elseif t == "BrickColor" then
		return { _type = "BrickColor", Name = value.Name, Number = value.Number }
	elseif t == "UDim" then
		return { _type = "UDim", Scale = value.Scale, Offset = value.Offset }
	elseif t == "UDim2" then
		return { _type = "UDim2", X = { Scale = value.X.Scale, Offset = value.X.Offset }, Y = { Scale = value.Y.Scale, Offset = value.Y.Offset } }
	elseif t == "Rect" then
		return { _type = "Rect", Min = { X = value.Min.X, Y = value.Min.Y }, Max = { X = value.Max.X, Y = value.Max.Y } }
	elseif t == "NumberRange" then
		return { _type = "NumberRange", Min = value.Min, Max = value.Max }
	elseif t == "NumberSequence" then
		local keypoints = {}
		for _, kp in ipairs(value.Keypoints) do
			table.insert(keypoints, { Time = kp.Time, Value = kp.Value, Envelope = kp.Envelope })
		end
		return { _type = "NumberSequence", Keypoints = keypoints }
	elseif t == "ColorSequence" then
		local keypoints = {}
		for _, kp in ipairs(value.Keypoints) do
			local c = kp.Value
			table.insert(keypoints, { Time = kp.Time, Color = { R = math.floor(c.R * 255), G = math.floor(c.G * 255), B = math.floor(c.B * 255) } })
		end
		return { _type = "ColorSequence", Keypoints = keypoints }
	elseif t == "EnumItem" then
		return { _type = "Enum", EnumType = tostring(value.EnumType), Name = value.Name, Value = value.Value }
	elseif t == "Enum" then
		return { _type = "Enum", Name = tostring(value) }
	elseif t == "Font" then
		return { _type = "Font", Family = value.Family, Weight = value.Weight.Name, Style = value.Style.Name }
	elseif t == "Ray" then
		return { _type = "Ray", Origin = { X = value.Origin.X, Y = value.Origin.Y, Z = value.Origin.Z }, Direction = { X = value.Direction.X, Y = value.Direction.Y, Z = value.Direction.Z } }
	elseif t == "PhysicalProperties" then
		return { _type = "PhysicalProperties", Density = value.Density, Friction = value.Friction, Elasticity = value.Elasticity, FrictionWeight = value.FrictionWeight, ElasticityWeight = value.ElasticityWeight }
	elseif t == "Axes" then
		return { _type = "Axes", X = value.X, Y = value.Y, Z = value.Z }
	elseif t == "Faces" then
		return { _type = "Faces", Top = value.Top, Bottom = value.Bottom, Left = value.Left, Right = value.Right, Front = value.Front, Back = value.Back }
	elseif t == "table" then
		-- Attempt shallow serialize
		local result = {}
		for k, v in pairs(value) do
			result[tostring(k)] = serializeValue(v)
		end
		return result
	else
		return tostring(value)
	end
end

------------------------------------------------------------------------
-- Utility: Deserialize JSON/Lua tables to Roblox native types
------------------------------------------------------------------------
local function deserializeValue(val)
	if type(val) ~= "table" then
		return val
	end

	local t = val._type
	if t == "Vector3" or (val.X ~= nil and val.Y ~= nil and val.Z ~= nil and val.R == nil and val.Scale == nil) then
		return Vector3.new(val.X or 0, val.Y or 0, val.Z or 0)
	elseif t == "Vector2" or (val.X ~= nil and val.Y ~= nil and val.Z == nil and val.Scale == nil) then
		return Vector2.new(val.X or 0, val.Y or 0)
	elseif t == "Color3" or (val.R ~= nil and val.G ~= nil and val.B ~= nil) then
		local r, g, b = val.R or 0, val.G or 0, val.B or 0
		if r > 1 or g > 1 or b > 1 then
			return Color3.fromRGB(r, g, b)
		else
			return Color3.new(r, g, b)
		end
	elseif t == "BrickColor" or val.BrickColorName then
		return BrickColor.new(val.Name or val.BrickColorName or "Medium stone grey")
	elseif t == "CFrame" or (val.Position and (val.Rotation or val.Orientation)) then
		local pos = val.Position
		local pVec = if type(pos) == "table" then Vector3.new(pos.X or 0, pos.Y or 0, pos.Z or 0) else Vector3.zero
		local rot = val.Rotation or val.Orientation or {}
		local rx = math.rad(rot.X or 0)
		local ry = math.rad(rot.Y or 0)
		local rz = math.rad(rot.Z or 0)
		return CFrame.new(pVec) * CFrame.Angles(rx, ry, rz)
	elseif t == "UDim2" or (val.X and val.Y and (val.X.Scale ~= nil or val.X.Offset ~= nil)) then
		local xs = (val.X and val.X.Scale) or 0
		local xo = (val.X and val.X.Offset) or 0
		local ys = (val.Y and val.Y.Scale) or 0
		local yo = (val.Y and val.Y.Offset) or 0
		return UDim2.new(xs, xo, ys, yo)
	elseif t == "UDim" or (val.Scale ~= nil and val.Offset ~= nil) then
		return UDim.new(val.Scale or 0, val.Offset or 0)
	elseif t == "NumberRange" or (val.Min ~= nil and val.Max ~= nil) then
		return NumberRange.new(val.Min or 0, val.Max or 0)
	elseif t == "Rect" then
		local min = val.Min or {}
		local max = val.Max or {}
		return Rect.new(min.X or 0, min.Y or 0, max.X or 0, max.Y or 0)
	end

	-- Array-style numeric values
	if #val == 3 and type(val[1]) == "number" and type(val[2]) == "number" and type(val[3]) == "number" then
		return Vector3.new(val[1], val[2], val[3])
	elseif #val == 2 and type(val[1]) == "number" and type(val[2]) == "number" then
		return Vector2.new(val[1], val[2])
	elseif #val == 4 and type(val[1]) == "number" then
		return UDim2.new(val[1], val[2], val[3], val[4])
	end

	return val
end

------------------------------------------------------------------------
-- Utility: Resolve a dot-separated path to an Instance
------------------------------------------------------------------------
local function resolvePath(path)
	if not path or path == "" then
		return nil, "Empty path"
	end

	if not string.find(path, "^game%.") and path ~= "game" then
		path = "game." .. path
	end

	local parts = string.split(path, ".")

	local current = game
	local i = 2
	while i <= #parts do
		local part = parts[i]
		local child = nil

		-- Handle instances with dots in their name (e.g. "IntroScreen.story")
		if i < #parts then
			local combinedPart = part .. "." .. parts[i + 1]
			local combinedChild = current:FindFirstChild(combinedPart)
			if combinedChild then
				child = combinedChild
				i += 1
			end
		end

		if not child then
			child = current:FindFirstChild(part)
		end

		if not child then
			-- Try as a service
			local success, service = pcall(function()
				return game:GetService(part)
			end)
			if success and service then
				current = service
			else
				return nil, string.format("Cannot find '%s' in '%s' (full path: %s)", part, current:GetFullName(), path)
			end
		else
			current = child
		end
		i += 1
	end

	return current, nil
end

------------------------------------------------------------------------
-- Utility: Get key summary properties based on ClassName
------------------------------------------------------------------------
local SUMMARY_PROPS = {
	-- Base
	default = { "Name", "ClassName" },

	-- Parts / 3D
	BasePart = { "Name", "ClassName", "Position", "Size", "Anchored", "CanCollide", "Transparency", "BrickColor", "Material" },
	MeshPart = { "Name", "ClassName", "Position", "Size", "Anchored", "MeshId", "TextureID", "Transparency" },
	UnionOperation = { "Name", "ClassName", "Position", "Size", "Anchored", "Transparency" },
	Model = { "Name", "ClassName", "PrimaryPart" },

	-- Scripts
	Script = { "Name", "ClassName", "Enabled", "RunContext" },
	LocalScript = { "Name", "ClassName", "Enabled" },
	ModuleScript = { "Name", "ClassName" },

	-- UI
	Frame = { "Name", "ClassName", "Size", "Position", "BackgroundColor3", "BackgroundTransparency", "Visible" },
	TextLabel = { "Name", "ClassName", "Text", "Size", "Position", "TextColor3", "TextSize", "Visible" },
	TextButton = { "Name", "ClassName", "Text", "Size", "Position", "Visible" },
	TextBox = { "Name", "ClassName", "Text", "PlaceholderText", "Size", "Visible" },
	ImageLabel = { "Name", "ClassName", "Image", "Size", "Position", "Visible" },
	ImageButton = { "Name", "ClassName", "Image", "Size", "Position", "Visible" },
	ScrollingFrame = { "Name", "ClassName", "Size", "CanvasSize", "Visible" },
	ScreenGui = { "Name", "ClassName", "Enabled", "ResetOnSpawn", "DisplayOrder" },
	BillboardGui = { "Name", "ClassName", "Size", "Enabled", "Adornee" },
	SurfaceGui = { "Name", "ClassName", "Face", "Enabled", "Adornee" },
	UIListLayout = { "Name", "ClassName", "FillDirection", "SortOrder", "Padding" },
	UIGridLayout = { "Name", "ClassName", "CellSize", "CellPadding", "SortOrder" },
	UIPadding = { "Name", "ClassName", "PaddingTop", "PaddingBottom", "PaddingLeft", "PaddingRight" },
	UICorner = { "Name", "ClassName", "CornerRadius" },
	UIStroke = { "Name", "ClassName", "Color", "Thickness", "Transparency" },

	-- Values
	StringValue = { "Name", "ClassName", "Value" },
	IntValue = { "Name", "ClassName", "Value" },
	NumberValue = { "Name", "ClassName", "Value" },
	BoolValue = { "Name", "ClassName", "Value" },
	ObjectValue = { "Name", "ClassName", "Value" },
	Color3Value = { "Name", "ClassName", "Value" },
	Vector3Value = { "Name", "ClassName", "Value" },
	CFrameValue = { "Name", "ClassName", "Value" },
	BrickColorValue = { "Name", "ClassName", "Value" },
	RayValue = { "Name", "ClassName", "Value" },

	-- Lighting / Effects
	PointLight = { "Name", "ClassName", "Color", "Brightness", "Range", "Enabled" },
	SpotLight = { "Name", "ClassName", "Color", "Brightness", "Range", "Angle", "Enabled" },
	SurfaceLight = { "Name", "ClassName", "Color", "Brightness", "Range", "Enabled" },
	ParticleEmitter = { "Name", "ClassName", "Texture", "Rate", "Enabled" },
	Beam = { "Name", "ClassName", "Enabled" },

	-- Sound
	Sound = { "Name", "ClassName", "SoundId", "Volume", "Playing", "Looped" },

	-- Animation
	Animation = { "Name", "ClassName", "AnimationId" },
	Animator = { "Name", "ClassName" },

	-- Physics
	BodyVelocity = { "Name", "ClassName", "Velocity", "MaxForce" },
	BodyForce = { "Name", "ClassName", "Force" },

	-- Other
	Folder = { "Name", "ClassName" },
	Camera = { "Name", "ClassName", "CFrame", "FieldOfView", "CameraType" },
	Humanoid = { "Name", "ClassName", "Health", "MaxHealth", "WalkSpeed", "JumpHeight" },
	Tool = { "Name", "ClassName", "ToolTip", "RequiresHandle", "CanBeDropped" },
	RemoteEvent = { "Name", "ClassName" },
	RemoteFunction = { "Name", "ClassName" },
	BindableEvent = { "Name", "ClassName" },
	BindableFunction = { "Name", "ClassName" },
	Attachment = { "Name", "ClassName", "CFrame" },
}

local function getSummaryProps(className)
	-- Direct match
	if SUMMARY_PROPS[className] then
		return SUMMARY_PROPS[className]
	end
	-- Fallback: check if it's a BasePart subclass
	-- We'll just use default
	return SUMMARY_PROPS.default
end

------------------------------------------------------------------------
-- Command Handlers
------------------------------------------------------------------------
local CommandHandlers = {}

function CommandHandlers.ls(params)
	local instance, err = resolvePath(params.path)
	if not instance then
		return nil, err
	end

	local children = instance:GetChildren()
	local result = {}

	for i, child in ipairs(children) do
		if i > MAX_CHILDREN_DEFAULT then
			table.insert(result, { Name = "...", ClassName = string.format("(%d more children truncated)", #children - MAX_CHILDREN_DEFAULT) })
			break
		end
		table.insert(result, {
			Name = child.Name,
			ClassName = child.ClassName,
			ChildCount = #child:GetChildren(),
		})
	end

	return {
		path = instance:GetFullName(),
		childCount = #children,
		children = result,
	}
end

function CommandHandlers.ls_descendants(params)
	local instance, err = resolvePath(params.path)
	if not instance then
		return nil, err
	end

	local maxDepth = params.max_depth or 5
	local count = 0
	local maxCount = MAX_DESCENDANTS_DEFAULT

	local function traverse(inst, depth)
		if depth > maxDepth or count > maxCount then
			return nil
		end

		local node = {
			Name = inst.Name,
			ClassName = inst.ClassName,
		}

		local children = inst:GetChildren()
		if #children > 0 and depth < maxDepth then
			node.Children = {}
			for _, child in ipairs(children) do
				count = count + 1
				if count > maxCount then
					table.insert(node.Children, { Name = "...", ClassName = string.format("(truncated at %d instances)", maxCount) })
					break
				end
				local childNode = traverse(child, depth + 1)
				if childNode then
					table.insert(node.Children, childNode)
				end
			end
		elseif #children > 0 then
			node.ChildCount = #children
			node.Note = "Max depth reached, children not expanded"
		end

		return node
	end

	local tree = traverse(instance, 0)
	return {
		path = instance:GetFullName(),
		totalDescendants = #instance:GetDescendants(),
		tree = tree,
	}
end

function CommandHandlers.ls_summary(params)
	local instance, err = resolvePath(params.path)
	if not instance then
		return nil, err
	end

	local children = instance:GetChildren()
	local result = {}

	for i, child in ipairs(children) do
		if i > MAX_CHILDREN_DEFAULT then
			table.insert(result, { Name = "...", ClassName = string.format("(%d more children truncated)", #children - MAX_CHILDREN_DEFAULT) })
			break
		end

		local propNames = getSummaryProps(child.ClassName)
		local props = {}

		for _, propName in ipairs(propNames) do
			if propName ~= "Name" and propName ~= "ClassName" then
				local success, value = pcall(function()
					return child[propName]
				end)
				if success and value ~= nil then
					props[propName] = serializeValue(value)
				end
			end
		end

		local entry = {
			Name = child.Name,
			ClassName = child.ClassName,
			ChildCount = #child:GetChildren(),
			Properties = props,
		}

		-- Include tags if any
		local tags = CollectionService:GetTags(child)
		if #tags > 0 then
			entry.Tags = tags
		end

		table.insert(result, entry)
	end

	return {
		path = instance:GetFullName(),
		childCount = #children,
		children = result,
	}
end

function CommandHandlers.get_properties(params)
	local instance, err = resolvePath(params.path)
	if not instance then
		return nil, err
	end

	local className = instance.ClassName
	local properties = {}

	-- Use ReflectionService to get all properties
	local success, propList = pcall(function()
		return ReflectionService:GetPropertiesOfClass(className, {
			ExcludeInherited = false,
			ExcludeDisplay = false,
		})
	end)

	if success and propList then
		for _, prop in ipairs(propList) do
			-- Try to read the property value
			local readSuccess, value = pcall(function()
				return instance[prop.Name]
			end)

			if readSuccess then
				properties[prop.Name] = {
					Value = serializeValue(value),
					Type = prop.Type or typeof(value),
					Serialized = prop.Serialized,
				}
			end
		end
	else
		-- Fallback: try common properties manually
		local commonProps = { "Name", "ClassName", "Parent", "Archivable" }
		for _, propName in ipairs(commonProps) do
			local readSuccess, value = pcall(function()
				return instance[propName]
			end)
			if readSuccess then
				properties[propName] = {
					Value = serializeValue(value),
					Type = typeof(value),
				}
			end
		end
		properties["_note"] = {
			Value = "ReflectionService unavailable, showing limited properties",
			Type = "string",
		}
	end

	-- Also include tags
	local tags = CollectionService:GetTags(instance)

	return {
		path = instance:GetFullName(),
		className = className,
		propertyCount = 0, -- will be counted below
		properties = properties,
		tags = tags,
	}
end

function CommandHandlers.get_by_tag(params)
	local tag = params.tag
	if not tag or tag == "" then
		return nil, "Tag name is required"
	end

	local tagged = CollectionService:GetTagged(tag)
	local result = {}

	for i, instance in ipairs(tagged) do
		if i > MAX_CHILDREN_DEFAULT then
			table.insert(result, { Path = "...", ClassName = string.format("(%d more instances truncated)", #tagged - MAX_CHILDREN_DEFAULT) })
			break
		end
		table.insert(result, {
			Name = instance.Name,
			ClassName = instance.ClassName,
			Path = instance:GetFullName(),
		})
	end

	return {
		tag = tag,
		count = #tagged,
		instances = result,
	}
end

function CommandHandlers.search(params)
	local instance, err = resolvePath(params.path)
	if not instance then
		return nil, err
	end

	local className = params.class_name
	local namePattern = params.name_pattern and string.lower(params.name_pattern) or nil
	local maxDepth = params.max_depth or 10
	local results = {}
	local maxResults = 200

	local function searchRecursive(inst, depth)
		if depth > maxDepth or #results >= maxResults then
			return
		end

		for _, child in ipairs(inst:GetChildren()) do
			if #results >= maxResults then
				break
			end

			local classMatch = (not className) or (child.ClassName == className) or child:IsA(className)
			local nameMatch = (not namePattern) or string.find(string.lower(child.Name), namePattern, 1, true)

			if classMatch and nameMatch then
				table.insert(results, {
					Name = child.Name,
					ClassName = child.ClassName,
					Path = child:GetFullName(),
				})
			end

			searchRecursive(child, depth + 1)
		end
	end

	searchRecursive(instance, 0)

	return {
		path = instance:GetFullName(),
		query = { class_name = className, name_pattern = params.name_pattern },
		resultCount = #results,
		truncated = #results >= maxResults,
		results = results,
	}
end

function CommandHandlers.get_viewport_size(params)
	local camera = workspace.CurrentCamera
	if not camera then
		return nil, "No active camera in workspace"
	end
	local viewportSize = camera.ViewportSize
	return {
		width = viewportSize.X,
		height = viewportSize.Y,
	}
end

function CommandHandlers.verify_script(params)
	local path = params.path
	if not path or path == "" then
		return nil, "path parameter is required"
	end

	local instance, err = resolvePath(path)
	if instance then
		local isScript = instance:IsA("LuaSourceContainer")
		local sourceLen = 0
		if isScript then
			pcall(function()
				sourceLen = #instance.Source
			end)
		end
		return {
			exists = true,
			path = instance:GetFullName(),
			name = instance.Name,
			className = instance.ClassName,
			isScript = isScript,
			sourceLength = sourceLen,
			message = string.format("Instance '%s' (%s) exists at '%s'.", instance.Name, instance.ClassName, instance:GetFullName())
		}
	end

	-- Does not exist
	if params.create_if_missing then
		local parentPath, targetName = string.match(path, "^(.+)%.([^%.]+)$")
		if parentPath and targetName then
			return CommandHandlers.create_script({
				parent_path = parentPath,
				name = targetName,
				script_type = params.script_type or "Script",
				source = params.source or ""
			})
		else
			return nil, string.format("Script does not exist at '%s' and could not parse parent/name from path.", path)
		end
	end

	return {
		exists = false,
		path = path,
		message = string.format("No script or instance exists at path: '%s'.", path)
	}
end

function CommandHandlers.create_script(params)
	local parentPath = params.parent_path
	local name = params.name
	local rawScriptType = params.script_type or "Script"
	local source = params.source or ""

	if not parentPath or parentPath == "" then
		return nil, "parent_path is required"
	end
	if not name or name == "" then
		return nil, "name is required"
	end

	local parentInstance, err = resolvePath(parentPath)
	if not parentInstance then
		return nil, "Parent path error: " .. (err or "Parent instance not found")
	end

	-- Check if script/instance already exists
	local existing = parentInstance:FindFirstChild(name)
	if existing then
		return {
			created = false,
			exists = true,
			path = existing:GetFullName(),
			className = existing.ClassName,
			message = string.format("Script '%s' already exists under '%s' (%s). Creation skipped.", name, parentInstance:GetFullName(), existing.ClassName)
		}
	end

	-- Normalize script_type
	local typeMap = {
		script = "Script",
		localscript = "LocalScript",
		modulescript = "ModuleScript"
	}
	local scriptType = typeMap[string.lower(rawScriptType)] or rawScriptType
	if scriptType ~= "Script" and scriptType ~= "LocalScript" and scriptType ~= "ModuleScript" then
		return nil, string.format("Invalid script_type '%s'. Must be 'Script', 'LocalScript', or 'ModuleScript'.", tostring(rawScriptType))
	end

	-- Default boilerplate for ModuleScript if source is empty
	if scriptType == "ModuleScript" and (not source or source == "") then
		source = "local " .. name .. " = {}\n\nreturn " .. name .. "\n"
	end

	-- Create new script instance
	local newScript = nil
	local createSuccess, createErr = pcall(function()
		local inst = Instance.new(scriptType)
		inst.Name = name
		inst.Source = source
		inst.Parent = parentInstance
		newScript = inst
	end)

	if not createSuccess or not newScript then
		return nil, "Failed to create " .. scriptType .. ": " .. tostring(createErr or "Unknown error")
	end

	pcall(function()
		ChangeHistoryService:SetWaypoint("MCP CreateScript: " .. name)
	end)

	return {
		created = true,
		exists = true,
		path = newScript:GetFullName(),
		className = newScript.ClassName,
		parent = parentInstance:GetFullName(),
		sourceLength = #source,
		message = string.format("Successfully created %s '%s' under '%s'.", scriptType, name, parentInstance:GetFullName())
	}
end

------------------------------------------------------------------------
-- UI Extraction Helpers & Handlers
------------------------------------------------------------------------

local UI_LAYOUT_CLASSES = {
	UIListLayout = true, UIGridLayout = true, UIPageLayout = true,
	UICorner = true, UIPadding = true, UIStroke = true,
	UIAspectRatioConstraint = true, UISizeConstraint = true, UITextSizeConstraint = true,
	UIGradient = true, UIScale = true, UIFlexItem = true,
}

local function colorToHex(color)
	if typeof(color) ~= "Color3" then return nil end
	return string.format("#%02X%02X%02X", math.floor(color.R * 255 + 0.5), math.floor(color.G * 255 + 0.5), math.floor(color.B * 255 + 0.5))
end

local function colorToRGB(color)
	if typeof(color) ~= "Color3" then return nil end
	return { math.floor(color.R * 255 + 0.5), math.floor(color.G * 255 + 0.5), math.floor(color.B * 255 + 0.5) }
end

local function udimToString(udim)
	if typeof(udim) ~= "UDim" then return nil end
	return string.format("{%g, %d}", udim.Scale, udim.Offset)
end

local function udim2ToString(udim2)
	if typeof(udim2) ~= "UDim2" then return nil end
	return string.format("{%g, %d}, {%g, %d}", udim2.X.Scale, udim2.X.Offset, udim2.Y.Scale, udim2.Y.Offset)
end

local function fontToString(font)
	local t = typeof(font)
	if t == "EnumItem" then
		return font.Name
	elseif t == "Font" then
		return font.Family
	elseif t == "string" then
		return font
	end
	return tostring(font)
end

local function isLayoutComponent(inst)
	if not inst then return false end
	return inst:IsA("UIGridStyleLayout") or inst:IsA("UIConstraint") or inst:IsA("UIPadding") or inst:IsA("UICorner") or inst:IsA("UIStroke") or inst:IsA("UIGradient") or inst:IsA("UIScale") or inst:IsA("UIFlexItem") or UI_LAYOUT_CLASSES[inst.ClassName] ~= nil
end

local function isUIInstance(inst)
	if not inst then return false end
	if inst:IsA("GuiObject") or inst:IsA("LayerCollector") or isLayoutComponent(inst) then
		return true
	end
	if inst:IsA("Folder") or inst:IsA("Configuration") or inst:IsA("Model") then
		for _, child in ipairs(inst:GetChildren()) do
			if isUIInstance(child) then
				return true
			end
		end
	end
	return false
end

local function extractDesignProperties(instance, includeDefaults)
	local layout = {}
	local style = {}
	local typography = {}

	-- Layout properties (GuiObject / LayerCollector)
	if instance:IsA("GuiObject") then
		layout.Position = udim2ToString(instance.Position)
		layout.Size = udim2ToString(instance.Size)

		if includeDefaults or (instance.AnchorPoint.X ~= 0 or instance.AnchorPoint.Y ~= 0) then
			layout.AnchorPoint = { instance.AnchorPoint.X, instance.AnchorPoint.Y }
		end
		if includeDefaults or instance.ZIndex ~= 1 then
			layout.ZIndex = instance.ZIndex
		end
		if includeDefaults or instance.LayoutOrder ~= 0 then
			layout.LayoutOrder = instance.LayoutOrder
		end
		if includeDefaults or instance.AutomaticSize ~= Enum.AutomaticSize.None then
			layout.AutomaticSize = instance.AutomaticSize.Name
		end
		if includeDefaults or instance.SizeConstraint ~= Enum.SizeConstraint.RelativeXY then
			layout.SizeConstraint = instance.SizeConstraint.Name
		end
		if includeDefaults or instance.Rotation ~= 0 then
			layout.Rotation = instance.Rotation
		end
		layout.Visible = instance.Visible
		if includeDefaults or instance.ClipsDescendants then
			layout.ClipsDescendants = instance.ClipsDescendants
		end

		-- Styling properties
		local bgTrans = instance.BackgroundTransparency
		if includeDefaults or bgTrans < 1 then
			style.BackgroundColor3 = colorToHex(instance.BackgroundColor3)
			style.BackgroundTransparency = bgTrans
		end

		local borderSize = instance.BorderSizePixel
		if includeDefaults or borderSize > 0 then
			style.BorderSizePixel = borderSize
			style.BorderColor3 = colorToHex(instance.BorderColor3)
		end
	end

	-- ImageLabel / ImageButton
	if instance:IsA("ImageLabel") or instance:IsA("ImageButton") then
		if instance.Image ~= "" then
			style.Image = instance.Image
			if includeDefaults or instance.ImageTransparency < 1 then
				style.ImageColor3 = colorToHex(instance.ImageColor3)
				if includeDefaults or instance.ImageTransparency > 0 then
					style.ImageTransparency = instance.ImageTransparency
				end
			end
			if includeDefaults or instance.ScaleType ~= Enum.ScaleType.Stretch then
				style.ScaleType = instance.ScaleType.Name
			end
		end
	end

	-- ScrollingFrame
	if instance:IsA("ScrollingFrame") then
		layout.CanvasSize = udim2ToString(instance.CanvasSize)
		if includeDefaults or instance.ScrollBarThickness ~= 12 then
			layout.ScrollBarThickness = instance.ScrollBarThickness
		end
	end

	-- Typography properties (TextLabel / TextButton / TextBox)
	if instance:IsA("TextLabel") or instance:IsA("TextButton") or instance:IsA("TextBox") then
		typography.Text = instance.Text
		typography.Font = fontToString(instance.Font)
		typography.TextSize = instance.TextSize
		typography.TextColor3 = colorToHex(instance.TextColor3)

		if includeDefaults or instance.TextTransparency > 0 then
			typography.TextTransparency = instance.TextTransparency
		end
		if includeDefaults or instance.TextScaled then
			typography.TextScaled = instance.TextScaled
		end
		if includeDefaults or instance.TextWrapped then
			typography.TextWrapped = instance.TextWrapped
		end
		if includeDefaults or instance.TextXAlignment ~= Enum.TextXAlignment.Center then
			typography.TextXAlignment = instance.TextXAlignment.Name
		end
		if includeDefaults or instance.TextYAlignment ~= Enum.TextYAlignment.Center then
			typography.TextYAlignment = instance.TextYAlignment.Name
		end
		if instance:IsA("TextBox") and (includeDefaults or instance.PlaceholderText ~= "") then
			typography.PlaceholderText = instance.PlaceholderText
		end
		if includeDefaults or instance.RichText then
			typography.RichText = instance.RichText
		end
	end

	local result = {}
	if next(layout) then result.layout = layout end
	if next(style) then result.style = style end
	if next(typography) then result.typography = typography end

	return result
end

local function extractModifier(child)
	local mod = { Class = child.ClassName }

	if child:IsA("UICorner") then
		mod.CornerRadius = udimToString(child.CornerRadius)
	elseif child:IsA("UIPadding") then
		if child.PaddingTop.Scale ~= 0 or child.PaddingTop.Offset ~= 0 then mod.PaddingTop = udimToString(child.PaddingTop) end
		if child.PaddingBottom.Scale ~= 0 or child.PaddingBottom.Offset ~= 0 then mod.PaddingBottom = udimToString(child.PaddingBottom) end
		if child.PaddingLeft.Scale ~= 0 or child.PaddingLeft.Offset ~= 0 then mod.PaddingLeft = udimToString(child.PaddingLeft) end
		if child.PaddingRight.Scale ~= 0 or child.PaddingRight.Offset ~= 0 then mod.PaddingRight = udimToString(child.PaddingRight) end
	elseif child:IsA("UIListLayout") then
		mod.FillDirection = child.FillDirection.Name
		mod.SortOrder = child.SortOrder.Name
		mod.Padding = udimToString(child.Padding)
		mod.HorizontalAlignment = child.HorizontalAlignment.Name
		mod.VerticalAlignment = child.VerticalAlignment.Name
	elseif child:IsA("UIGridLayout") then
		mod.CellSize = udim2ToString(child.CellSize)
		mod.CellPadding = udim2ToString(child.CellPadding)
		mod.SortOrder = child.SortOrder.Name
	elseif child:IsA("UIAspectRatioConstraint") then
		mod.AspectRatio = child.AspectRatio
		mod.AspectType = child.AspectType.Name
		mod.DominantAxis = child.DominantAxis.Name
	elseif child:IsA("UIStroke") then
		mod.Color = colorToHex(child.Color)
		mod.Thickness = child.Thickness
		mod.Transparency = child.Transparency
		mod.ApplyStrokeMode = child.ApplyStrokeMode.Name
	elseif child:IsA("UIGradient") then
		mod.Rotation = child.Rotation
	elseif child:IsA("UIScale") then
		mod.Scale = child.Scale
	elseif child:IsA("UIFlexItem") then
		mod.FlexMode = child.FlexMode.Name
	end

	return mod
end

function CommandHandlers.get_ui_tree(params)
	local instance, err = resolvePath(params.path)
	if not instance then
		return nil, err
	end

	local maxDepth = params.max_depth or 4
	local includeLayout = params.include_layout_components
	if includeLayout == nil then includeLayout = true end

	local function traverse(inst, depth)
		if depth > maxDepth then return nil end

		local node = {
			Name = inst.Name,
			Class = inst.ClassName,
		}

		local rawChildren = inst:GetChildren()
		local validChildren = {}

		for _, child in ipairs(rawChildren) do
			if isUIInstance(child) then
				if not includeLayout and isLayoutComponent(child) then
					-- Skip layout components if false
				else
					table.insert(validChildren, child)
				end
			end
		end

		if #validChildren > 0 and depth < maxDepth then
			node.Children = {}
			for _, child in ipairs(validChildren) do
				local childNode = traverse(child, depth + 1)
				if childNode then
					table.insert(node.Children, childNode)
				end
			end
		end

		return node
	end

	local tree = traverse(instance, 0)
	return {
		path = instance:GetFullName(),
		tree = tree,
	}
end

function CommandHandlers.get_ui_design_properties(params)
	local instance, err = resolvePath(params.path)
	if not instance then
		return nil, err
	end

	local includeDefaults = params.include_defaults or false
	local designProps = extractDesignProperties(instance, includeDefaults)

	local response = {
		path = instance:GetFullName(),
		class = instance.ClassName,
	}

	if designProps.layout then response.layout = designProps.layout end
	if designProps.style then response.style = designProps.style end
	if designProps.typography then response.typography = designProps.typography end

	return response
end

function CommandHandlers.inspect_ui_component(params)
	local instance, err = resolvePath(params.path)
	if not instance then
		return nil, err
	end

	local includeDefaults = false
	local designProps = extractDesignProperties(instance, includeDefaults)

	local combinedProps = {}
	if designProps.layout then
		for k, v in pairs(designProps.layout) do combinedProps[k] = v end
	end
	if designProps.style then
		for k, v in pairs(designProps.style) do combinedProps[k] = v end
	end
	if designProps.typography then
		for k, v in pairs(designProps.typography) do combinedProps[k] = v end
	end

	local modifiers = {}
	for _, child in ipairs(instance:GetChildren()) do
		if isLayoutComponent(child) then
			table.insert(modifiers, extractModifier(child))
		end
	end

	return {
		path = instance:GetFullName(),
		class = instance.ClassName,
		properties = combinedProps,
		modifiers = modifiers,
	}
end

function CommandHandlers.get_ui_palette(params)
	local instance, err = resolvePath(params.path)
	if not instance then
		return nil, err
	end

	local includeCounts = params.include_counts
	if includeCounts == nil then includeCounts = true end

	local colorMap = {}
	local fontMap = {}
	local imageMap = {}
	local cornerRadiiMap = {}
	local paddingsMap = {}

	local totalScanned = 0

	local function addColor(color, propName, isVisible)
		if not isVisible or typeof(color) ~= "Color3" then return end
		local hex = colorToHex(color)
		if not hex then return end

		if not colorMap[hex] then
			colorMap[hex] = {
				hex = hex,
				rgb = colorToRGB(color),
				usedInMap = {},
				count = 0,
			}
		end
		colorMap[hex].count += 1
		colorMap[hex].usedInMap[propName] = true
	end

	local function scanInstance(inst)
		if not isUIInstance(inst) then return end
		totalScanned += 1

		local isVisible = true
		if inst:IsA("GuiObject") then
			isVisible = inst.Visible
		end

		-- Colors
		if inst:IsA("GuiObject") then
			if inst.BackgroundTransparency < 1 then
				addColor(inst.BackgroundColor3, "BackgroundColor3", isVisible)
			end
			if inst.BorderSizePixel > 0 then
				addColor(inst.BorderColor3, "BorderColor3", isVisible)
			end
		end

		if inst:IsA("TextLabel") or inst:IsA("TextButton") or inst:IsA("TextBox") then
			if inst.TextTransparency < 1 then
				addColor(inst.TextColor3, "TextColor3", isVisible)
			end
			-- Typography
			local fontName = fontToString(inst.Font)
			if not fontMap[fontName] then
				fontMap[fontName] = { font = fontName, sizeMap = {}, count = 0 }
			end
			fontMap[fontName].count += 1
			fontMap[fontName].sizeMap[inst.TextSize] = true
		end

		if inst:IsA("ImageLabel") or inst:IsA("ImageButton") then
			if inst.Image ~= "" then
				if inst.ImageTransparency < 1 then
					addColor(inst.ImageColor3, "ImageColor3", isVisible)
				end

				local assetId = inst.Image
				if not imageMap[assetId] then
					imageMap[assetId] = { assetId = assetId, usedInMap = {}, scaleTypeMap = {}, count = 0 }
				end
				imageMap[assetId].count += 1
				imageMap[assetId].usedInMap[inst.ClassName] = true
				imageMap[assetId].scaleTypeMap[inst.ScaleType.Name] = true
			end
		end

		-- Modifiers
		if inst:IsA("UICorner") then
			cornerRadiiMap[udimToString(inst.CornerRadius)] = true
		elseif inst:IsA("UIPadding") then
			if inst.PaddingTop.Scale ~= 0 or inst.PaddingTop.Offset ~= 0 then paddingsMap[udimToString(inst.PaddingTop)] = true end
			if inst.PaddingBottom.Scale ~= 0 or inst.PaddingBottom.Offset ~= 0 then paddingsMap[udimToString(inst.PaddingBottom)] = true end
			if inst.PaddingLeft.Scale ~= 0 or inst.PaddingLeft.Offset ~= 0 then paddingsMap[udimToString(inst.PaddingLeft)] = true end
			if inst.PaddingRight.Scale ~= 0 or inst.PaddingRight.Offset ~= 0 then paddingsMap[udimToString(inst.PaddingRight)] = true end
		elseif inst:IsA("UIStroke") then
			if inst.Transparency < 1 then
				addColor(inst.Color, "UIStrokeColor", true)
			end
		end

		for _, child in ipairs(inst:GetChildren()) do
			scanInstance(child)
		end
	end

	scanInstance(instance)

	-- Format output lists
	local colors = {}
	for hex, data in pairs(colorMap) do
		local usedIn = {}
		for k in pairs(data.usedInMap) do table.insert(usedIn, k) end
		table.sort(usedIn)

		local item = { hex = data.hex, rgb = data.rgb, usedIn = usedIn }
		if includeCounts then item.count = data.count end
		table.insert(colors, item)
	end
	table.sort(colors, function(a, b) return (a.count or 0) > (b.count or 0) end)

	local typography = {}
	for fontName, data in pairs(fontMap) do
		local sizes = {}
		for s in pairs(data.sizeMap) do table.insert(sizes, s) end
		table.sort(sizes)

		local item = { font = data.font, sizes = sizes }
		if includeCounts then item.count = data.count end
		table.insert(typography, item)
	end
	table.sort(typography, function(a, b) return (a.count or 0) > (b.count or 0) end)

	local images = {}
	for assetId, data in pairs(imageMap) do
		local usedIn = {}
		for k in pairs(data.usedInMap) do table.insert(usedIn, k) end
		table.sort(usedIn)

		local scaleTypes = {}
		for k in pairs(data.scaleTypeMap) do table.insert(scaleTypes, k) end
		table.sort(scaleTypes)

		local item = { assetId = data.assetId, usedIn = usedIn, scaleTypes = scaleTypes }
		if includeCounts then item.count = data.count end
		table.insert(images, item)
	end

	local cornerRadii = {}
	for r in pairs(cornerRadiiMap) do table.insert(cornerRadii, r) end
	table.sort(cornerRadii)

	local paddings = {}
	for p in pairs(paddingsMap) do table.insert(paddings, p) end
	table.sort(paddings)

	return {
		path = instance:GetFullName(),
		totalElementsScanned = totalScanned,
		palette = {
			colors = colors,
			typography = typography,
			images = images,
			layoutMetrics = {
				cornerRadii = cornerRadii,
				paddings = paddings,
			},
		},
	}
end

------------------------------------------------------------------------
-- UI Story Mounting & Lifecycle Management
------------------------------------------------------------------------

local mountedStories = {}

local function getOrCreatePreviewFolder(): Folder
	local starterGui = game:GetService("StarterGui")
	local folder = starterGui:FindFirstChild("_MCP_Mounted_Stories")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "_MCP_Mounted_Stories"
		folder.Parent = starterGui
	end
	return folder :: Folder
end

local function getLogLevel(messageType)
	if messageType == Enum.MessageType.MessageError then
		return "error"
	elseif messageType == Enum.MessageType.MessageWarning then
		return "warning"
	elseif messageType == Enum.MessageType.MessageInfo then
		return "info"
	else
		return "normal"
	end
end

local function getMessageTypeName(messageType)
	if typeof(messageType) == "EnumItem" then
		return messageType.Name
	end
	return tostring(messageType)
end

function CommandHandlers.mount_story(params)
	local path = params.path
	if not path or path == "" then
		return {
			success = false,
			error = "path parameter is required",
			logs = {},
			hasErrors = true,
			hasWarnings = false,
			errorCount = 1,
			warningCount = 0,
			logCount = 0,
			message = "path parameter is required",
		}
	end

	local instance, resolveErr = resolvePath(path)
	if not instance then
		return {
			success = false,
			error = resolveErr or "Instance not found",
			logs = {},
			hasErrors = true,
			hasWarnings = false,
			errorCount = 1,
			warningCount = 0,
			logCount = 0,
			message = resolveErr or "Instance not found",
		}
	end
	if not instance:IsA("ModuleScript") then
		local err = string.format("Target '%s' is not a ModuleScript (%s).", instance:GetFullName(), instance.ClassName)
		return {
			success = false,
			error = err,
			logs = {},
			hasErrors = true,
			hasWarnings = false,
			errorCount = 1,
			warningCount = 0,
			logCount = 0,
			message = err,
		}
	end

	-- Start capturing output logs during mount lifecycle
	local capturedLogs = {}
	local initialLogHistoryCount = 0
	pcall(function()
		local history = LogService:GetLogHistory()
		initialLogHistoryCount = #history
	end)

	local logConnection = nil
	pcall(function()
		logConnection = LogService.MessageOut:Connect(function(msg, msgType)
			table.insert(capturedLogs, {
				message = tostring(msg),
				level = getLogLevel(msgType),
				messageType = getMessageTypeName(msgType),
				timestamp = os.time(),
			})
		end)
	end)

	local function completeMount(success: boolean, errorMessage: string?, screenGui: Instance?, reactRoot: any, cleanupFn: any, effectiveControls: any)
		-- Allow immediate deferred microtasks/render warnings to flush
		task.wait(0.05)

		if logConnection then
			pcall(function()
				logConnection:Disconnect()
			end)
			logConnection = nil
		end

		-- If an explicit error occurred, ensure it is recorded in logs
		if errorMessage then
			table.insert(capturedLogs, {
				message = errorMessage,
				level = "error",
				messageType = "MessageError",
				timestamp = os.time(),
			})
		end

		-- Complement with any engine history entries missed by MessageOut
		pcall(function()
			local currentHistory = LogService:GetLogHistory()
			if #currentHistory > initialLogHistoryCount then
				for i = initialLogHistoryCount + 1, #currentHistory do
					local entry = currentHistory[i]
					local msg = tostring(entry.message)
					local exists = false
					for _, existing in ipairs(capturedLogs) do
						if existing.message == msg then
							exists = true
							break
						end
					end
					if not exists then
						table.insert(capturedLogs, {
							message = msg,
							level = getLogLevel(entry.messageType),
							messageType = getMessageTypeName(entry.messageType),
							timestamp = entry.timestamp or os.time(),
						})
					end
				end
			end
		end)

		local errorCount = 0
		local warningCount = 0
		local normalCount = 0
		for _, logEntry in ipairs(capturedLogs) do
			if logEntry.level == "error" then
				errorCount += 1
			elseif logEntry.level == "warning" then
				warningCount += 1
			else
				normalCount += 1
			end
		end

		if not success then
			return {
				success = false,
				error = errorMessage or "Mount failed",
				path = instance:GetFullName(),
				name = instance.Name,
				guiPath = if screenGui then screenGui:GetFullName() else nil,
				controls = effectiveControls or {},
				logs = capturedLogs,
				hasErrors = true,
				hasWarnings = warningCount > 0,
				errorCount = math.max(errorCount, 1),
				warningCount = warningCount,
				logCount = #capturedLogs,
				message = errorMessage or "Failed to mount story.",
			}
		end

		mountedStories[instance] = {
			instance = instance,
			path = instance:GetFullName(),
			screenGui = screenGui,
			root = reactRoot,
			cleanup = cleanupFn,
			controls = effectiveControls,
			mountedAt = os.time(),
		}

		local totalMounted = 0
		for _ in pairs(mountedStories) do
			totalMounted += 1
		end

		return {
			success = true,
			path = instance:GetFullName(),
			name = instance.Name,
			guiPath = screenGui:GetFullName(),
			controls = effectiveControls,
			totalMounted = totalMounted,
			logs = capturedLogs,
			hasErrors = errorCount > 0,
			hasWarnings = warningCount > 0,
			errorCount = errorCount,
			warningCount = warningCount,
			logCount = #capturedLogs,
			message = string.format("Successfully mounted '%s' in StarterGui (errors: %d, warnings: %d).", instance.Name, errorCount, warningCount),
		}
	end

	-- If previously mounted, clean up the prior mount
	if mountedStories[instance] then
		local prev = mountedStories[instance]
		mountedStories[instance] = nil
		pcall(function()
			if prev.root and prev.root.unmount then
				prev.root:unmount()
			end
			if prev.cleanup then
				prev.cleanup()
			end
			if prev.screenGui then
				prev.screenGui:Destroy()
			end
		end)
	end

	-- Require the story module (clone parent to bypass Luau require cache for story and sibling modules)
	local clonedToClean = nil
	local reqSuccess, storyModule = pcall(function()
		local parent = instance.Parent
		if parent then
			local clonedParent = parent:Clone()
			clonedToClean = clonedParent
			pcall(function()
				clonedParent.Parent = parent.Parent
			end)
			local clonedStory = clonedParent:FindFirstChild(instance.Name)
			if clonedStory and clonedStory:IsA("ModuleScript") then
				return require(clonedStory)
			end
		end
		local cloned = instance:Clone()
		clonedToClean = cloned
		pcall(function()
			cloned.Parent = instance.Parent
		end)
		return require(cloned)
	end)

	if clonedToClean then
		task.defer(function()
			pcall(function()
				clonedToClean:Destroy()
			end)
		end)
	end

	if not reqSuccess then
		return completeMount(false, string.format("Failed to require story module '%s': %s", instance:GetFullName(), tostring(storyModule)))
	end

	-- Create dedicated ScreenGui for this story
	local previewFolder = getOrCreatePreviewFolder()
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "Story_" .. string.gsub(instance.Name, "[^%w_]", "_")
	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = true
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screenGui.DisplayOrder = 100
	screenGui.Parent = previewFolder

	-- Resolve React & ReactRoblox
	local React = nil
	local ReactRoblox = nil

	if typeof(storyModule) == "table" then
		React = storyModule.react or storyModule.React
		ReactRoblox = storyModule.reactRoblox or storyModule.ReactRoblox
	end

	if not React then
		pcall(function()
			React = require(game.ReplicatedStorage.Modules.React)
		end)
	end
	if not ReactRoblox then
		pcall(function()
			ReactRoblox = require(game.ReplicatedStorage.Modules.ReactRoblox)
		end)
	end

	-- Merge controls
	local effectiveControls = {}
	if typeof(storyModule) == "table" and typeof(storyModule.controls) == "table" then
		for k, v in pairs(storyModule.controls) do
			effectiveControls[k] = v
		end
	end
	if typeof(params.controls) == "table" then
		for k, v in pairs(params.controls) do
			effectiveControls[k] = v
		end
	end

	local reactRoot = nil
	local cleanupFn = nil

	if typeof(storyModule) == "table" and (storyModule.story or storyModule.render) then
		local renderFn = storyModule.story or storyModule.render
		if typeof(renderFn) == "function" then
			local callSuccess, callResult = pcall(function()
				return renderFn({
					controls = effectiveControls,
					target = screenGui,
					scope = {},
				})
			end)

			if not callSuccess then
				screenGui:Destroy()
				return completeMount(false, string.format("Error executing story render: %s", tostring(callResult)), nil, nil, nil, effectiveControls)
			end

			if typeof(callResult) == "function" then
				cleanupFn = callResult
			elseif callResult ~= nil and ReactRoblox then
				local mountSuccess, mountResult = pcall(function()
					local root = ReactRoblox.createRoot(screenGui)
					root:render(callResult)
					return root
				end)
				if mountSuccess then
					reactRoot = mountResult
				else
					screenGui:Destroy()
					return completeMount(false, string.format("ReactRoblox mount failed: %s", tostring(mountResult)), nil, nil, nil, effectiveControls)
				end
			end
		end
	elseif typeof(storyModule) == "function" then
		local callSuccess, callResult = pcall(function()
			return storyModule(screenGui)
		end)
		if not callSuccess then
			screenGui:Destroy()
			return completeMount(false, string.format("Error executing functional story: %s", tostring(callResult)), nil, nil, nil, effectiveControls)
		end
		if typeof(callResult) == "function" then
			cleanupFn = callResult
		end
	end

	return completeMount(true, nil, screenGui, reactRoot, cleanupFn, effectiveControls)
end

function CommandHandlers.unmount_story(params)
	local path = params.path
	if not path or path == "" then
		return nil, "path parameter is required"
	end

	local instance = resolvePath(path)
	local targetEntry = nil
	local targetKey = nil

	if instance and mountedStories[instance] then
		targetKey = instance
		targetEntry = mountedStories[instance]
	else
		for inst, data in pairs(mountedStories) do
			if data.path == path or string.find(data.path, path, 1, true) then
				targetKey = inst
				targetEntry = data
				break
			end
		end
	end

	if not targetEntry then
		-- Fallback: check if orphan ScreenGui exists in _MCP_Mounted_Stories
		local starterGui = game:GetService("StarterGui")
		local folder = starterGui:FindFirstChild("_MCP_Mounted_Stories")
		if folder then
			local sanitized = string.gsub(path, "[^%w_]", "_")
			local gui = folder:FindFirstChild("Story_" .. sanitized) or folder:FindFirstChild(path)
			if gui then
				gui:Destroy()
				return {
					success = true,
					path = path,
					message = string.format("Removed unindexed ScreenGui '%s'.", gui.Name),
				}
			end
		end

		return {
			success = false,
			path = path,
			message = string.format("No mounted story found matching '%s'.", path),
		}
	end

	mountedStories[targetKey] = nil

	pcall(function()
		if targetEntry.root and targetEntry.root.unmount then
			targetEntry.root:unmount()
		end
		if targetEntry.cleanup then
			targetEntry.cleanup()
		end
		if targetEntry.screenGui then
			targetEntry.screenGui:Destroy()
		end
	end)

	return {
		success = true,
		path = targetEntry.path,
		message = string.format("Successfully unmounted story '%s'.", targetEntry.path),
	}
end

function CommandHandlers.list_mounted_stories(_params)
	local stories = {}
	for _, data in pairs(mountedStories) do
		table.insert(stories, {
			path = data.path,
			guiPath = if data.screenGui then data.screenGui:GetFullName() else nil,
			controls = data.controls,
			mountedAt = data.mountedAt,
		})
	end

	return {
		count = #stories,
		stories = stories,
	}
end

function CommandHandlers.unmount_all_stories(_params)
	local count = 0
	for inst, data in pairs(mountedStories) do
		count += 1
		pcall(function()
			if data.root and data.root.unmount then
				data.root:unmount()
			end
			if data.cleanup then
				data.cleanup()
			end
			if data.screenGui then
				data.screenGui:Destroy()
			end
		end)
	end
	table.clear(mountedStories)

	local starterGui = game:GetService("StarterGui")
	local folder = starterGui:FindFirstChild("_MCP_Mounted_Stories")
	if folder then
		folder:ClearAllChildren()
	end

	return {
		success = true,
		unmountedCount = count,
		message = string.format("Successfully unmounted all (%d) stories.", count),
	}
end

function CommandHandlers.execute_code(params)
	local code = params.code
	if not code or code == "" then
		return nil, "code parameter is required"
	end

	-- Reject requests containing the 'require' keyword
	if string.match(string.lower(code), "%f[%w_]require%f[%W]") then
		return nil, "Execution rejected: 'require' is not permitted in execute_code"
	end

	local recording = nil
	pcall(function()
		if ChangeHistoryService.TryBeginRecording then
			recording = ChangeHistoryService:TryBeginRecording("MCP Execute Code")
		else
			ChangeHistoryService:SetWaypoint("MCP Execute Code")
		end
	end)

	local capturedLogs = {}
	local env = setmetatable({
		require = function(...)
			error("Execution rejected: 'require' is not permitted in execute_code", 2)
		end,
		print = function(...)
			local parts = {}
			for i = 1, select("#", ...) do
				table.insert(parts, tostring(select(i, ...)))
			end
			table.insert(capturedLogs, table.concat(parts, " "))
		end,
		warn = function(...)
			local parts = {}
			for i = 1, select("#", ...) do
				table.insert(parts, tostring(select(i, ...)))
			end
			table.insert(capturedLogs, "[WARN] " .. table.concat(parts, " "))
		end,
	}, { __index = getfenv() })

	-- Dual-stage compiler: Try standard loadstring, fallback to ModuleScript execution
	local fn = nil
	local parseErr = nil

	local okLoad, loadResult = pcall(function()
		return loadstring(code)
	end)

	if okLoad and typeof(loadResult) == "function" then
		fn = loadResult
	else
		-- ModuleScript compilation fallback with Plugin Security (runs even when LoadStringEnabled is false)
		local tempMod = Instance.new("ModuleScript")
		tempMod.Name = "_MCPExecTemp_" .. HttpService:GenerateGUID(false)
		tempMod.Source = "return function()\n" .. code .. "\nend"

		pcall(function()
			tempMod.Parent = game:GetService("CoreGui") or game:GetService("ReplicatedStorage")
		end)

		local okReq, factory = pcall(require, tempMod)
		pcall(function()
			tempMod:Destroy()
		end)

		if okReq and typeof(factory) == "function" then
			fn = factory
		else
			parseErr = tostring(factory or loadResult or "Compilation failed")
		end
	end

	if not fn then
		if recording then
			pcall(function()
				ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Cancel)
			end)
		end
		return nil, "Syntax/Compilation error: " .. tostring(parseErr)
	end

	setfenv(fn, env)

	local ok, ret = pcall(fn)
	if not ok then
		if recording then
			pcall(function()
				ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Cancel)
			end)
		end
		return nil, "Runtime error: " .. tostring(ret)
	end

	if recording then
		pcall(function()
			ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
		end)
	else
		pcall(function()
			ChangeHistoryService:SetWaypoint("MCP Execute Code")
		end)
	end

	return {
		success = true,
		result = serializeValue(ret),
		logs = capturedLogs,
	}
end

function CommandHandlers.get_output_logs(params)
	local maxLines = math.min(math.max(1, tonumber(params.max_lines) or 50), 200)
	local filterType = params.message_type

	local success, logs = pcall(function()
		return LogService:GetLogHistory()
	end)

	if not success or not logs then
		return nil, "Failed to retrieve log history: " .. tostring(logs)
	end

	local results = {}
	local startIndex = math.max(1, #logs - maxLines + 1)

	for i = startIndex, #logs do
		local entry = logs[i]
		local msgType = entry.messageType
		local typeName = if typeof(msgType) == "EnumItem" then msgType.Name else tostring(msgType)
		local simpleType = typeName:gsub("^Message", "")

		local matches = true
		if filterType and filterType ~= "" then
			local fLower = string.lower(filterType)
			matches = (string.lower(simpleType) == fLower or string.lower(typeName) == fLower)
		end

		if matches then
			table.insert(results, {
				message = entry.message,
				messageType = simpleType,
				timestamp = entry.timestamp,
			})
		end
	end

	return {
		totalCount = #results,
		logs = results,
	}
end

function CommandHandlers.set_properties(params)
	local instance, err = resolvePath(params.path)
	if not instance then
		return nil, err
	end

	local properties = params.properties
	if type(properties) ~= "table" then
		return nil, "properties must be a dictionary"
	end

	local recording = nil
	pcall(function()
		if ChangeHistoryService.TryBeginRecording then
			recording = ChangeHistoryService:TryBeginRecording("MCP Set Properties")
		else
			ChangeHistoryService:SetWaypoint("MCP Set Properties")
		end
	end)

	local updated = {}
	local errors = {}

	for propName, rawValue in pairs(properties) do
		local success, setErr = pcall(function()
			local converted = deserializeValue(rawValue)
			instance[propName] = converted
		end)

		if success then
			table.insert(updated, propName)
		else
			errors[propName] = tostring(setErr)
		end
	end

	if recording then
		pcall(function()
			ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
		end)
	else
		pcall(function()
			ChangeHistoryService:SetWaypoint("MCP Set Properties")
		end)
	end

	return {
		success = #errors == 0,
		path = instance:GetFullName(),
		updatedProperties = updated,
		errors = if next(errors) ~= nil then errors else nil,
	}
end

function CommandHandlers.set_attribute(params)
	local instance, err = resolvePath(params.path)
	if not instance then
		return nil, err
	end

	local attrName = params.attribute_name
	if not attrName or attrName == "" then
		return nil, "attribute_name is required"
	end

	local val = params.value
	local converted = if val ~= nil then deserializeValue(val) else nil

	local recording = nil
	pcall(function()
		if ChangeHistoryService.TryBeginRecording then
			recording = ChangeHistoryService:TryBeginRecording("MCP Set Attribute")
		else
			ChangeHistoryService:SetWaypoint("MCP Set Attribute")
		end
	end)

	local ok, setErr = pcall(function()
		instance:SetAttribute(attrName, converted)
	end)

	if recording then
		pcall(function()
			ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
		end)
	else
		pcall(function()
			ChangeHistoryService:SetWaypoint("MCP Set Attribute")
		end)
	end

	if not ok then
		return nil, "Failed to set attribute: " .. tostring(setErr)
	end

	return {
		success = true,
		path = instance:GetFullName(),
		attribute = attrName,
		value = serializeValue(converted),
	}
end

function CommandHandlers.get_attributes(params)
	local instance, err = resolvePath(params.path)
	if not instance then
		return nil, err
	end

	local attrs = instance:GetAttributes()
	local serialized = {}
	local count = 0
	for k, v in pairs(attrs) do
		count += 1
		serialized[k] = serializeValue(v)
	end

	return {
		path = instance:GetFullName(),
		attributeCount = count,
		attributes = serialized,
	}
end

function CommandHandlers.get_selection(_params)
	local selected = Selection:Get()
	local result = {}
	for _, inst in ipairs(selected) do
		table.insert(result, {
			Name = inst.Name,
			ClassName = inst.ClassName,
			Path = inst:GetFullName(),
		})
	end

	return {
		count = #result,
		selection = result,
	}
end

function CommandHandlers.set_selection(params)
	local paths = params.paths
	if type(paths) ~= "table" then
		return nil, "paths must be a list of dot-separated paths"
	end

	local instances = {}
	local resolvedPaths = {}
	local notFound = {}

	for _, p in ipairs(paths) do
		local inst, _err = resolvePath(p)
		if inst then
			table.insert(instances, inst)
			table.insert(resolvedPaths, inst:GetFullName())
		else
			table.insert(notFound, p)
		end
	end

	Selection:Set(instances)

	return {
		success = true,
		selectedCount = #instances,
		selected = resolvedPaths,
		notFound = if #notFound > 0 then notFound else nil,
	}
end

function CommandHandlers.focus_on_selection(params)
	local targetInstance = nil
	if params.path and params.path ~= "" then
		local inst, err = resolvePath(params.path)
		if not inst then
			return nil, err
		end
		targetInstance = inst
		Selection:Set({ inst })
	else
		local sel = Selection:Get()
		if #sel == 0 then
			return nil, "No instances currently selected in Studio, and no path was provided."
		end
		targetInstance = sel[1]
	end

	local camera = workspace.CurrentCamera
	if not camera then
		return nil, "CurrentCamera not found in Workspace"
	end

	local targetCF, targetSize = nil, Vector3.new(4, 4, 4)
	if targetInstance:IsA("Model") then
		targetCF, targetSize = targetInstance:GetBoundingBox()
	elseif targetInstance:IsA("BasePart") then
		targetCF = targetInstance.CFrame
		targetSize = targetInstance.Size
	elseif targetInstance:IsA("Attachment") then
		targetCF = targetInstance.WorldCFrame
		targetSize = Vector3.new(2, 2, 2)
	else
		local part = targetInstance:FindFirstChildWhichIsA("BasePart", true)
		if part then
			targetCF = part.CFrame
			targetSize = part.Size
		else
			return nil, string.format("Cannot focus on '%s' (%s): instance has no 3D position.", targetInstance.Name, targetInstance.ClassName)
		end
	end

	local distance = math.max(targetSize.Magnitude * 1.5, 6)
	local lookDir = camera.CFrame.LookVector
	local newPos = targetCF.Position - (lookDir * distance) + Vector3.new(0, targetSize.Y * 0.3, 0)

	camera.CFrame = CFrame.lookAt(newPos, targetCF.Position)
	camera.Focus = targetCF

	return {
		success = true,
		focusedInstance = targetInstance:GetFullName(),
		cameraPosition = serializeValue(camera.CFrame.Position),
		distance = distance,
	}
end

------------------------------------------------------------------------
-- Playtesting & Autonomous Automation Handlers
------------------------------------------------------------------------

local function getInstancePosition(inst)
	if not inst then return nil, nil end
	if inst:IsA("BasePart") then
		return inst.Position, inst.CFrame
	elseif inst:IsA("Attachment") then
		return inst.WorldPosition, inst.WorldCFrame
	elseif inst:IsA("Model") then
		if inst.PrimaryPart then
			return inst.PrimaryPart.Position, inst.PrimaryPart.CFrame
		else
			local cf = inst:GetBoundingBox()
			return cf.Position, cf
		end
	elseif inst:IsA("ProximityPrompt") and inst.Parent then
		return getInstancePosition(inst.Parent)
	else
		local part = inst:FindFirstChildWhichIsA("BasePart", true)
		if part then
			return part.Position, part.CFrame
		end
	end
	return nil, nil
end

function CommandHandlers.get_active_proximity_prompts(params)
	local maxDist = tonumber(params.max_distance) or 40
	local localPlayer = Players.LocalPlayer or Players:GetPlayers()[1]
	local char = localPlayer and localPlayer.Character
	local root = char and (char:FindFirstChild("HumanoidRootPart") or char.PrimaryPart)
	local refPos = root and root.Position or (workspace.CurrentCamera and workspace.CurrentCamera.CFrame.Position)
	local playerGui = localPlayer and localPlayer:FindFirstChild("PlayerGui")

	local results = {}
	local seenPromptMap = {}

	-- 1. Grab actively displayed custom prompts from CustomProximityPrompts (PlayerGui.ProximityPrompts)
	local customPromptsGui = playerGui and playerGui:FindFirstChild("ProximityPrompts")
	if customPromptsGui then
		for _, child in ipairs(customPromptsGui:GetChildren()) do
			if child:IsA("BillboardGui") and child.Name == "CustomProximityPrompt" then
				local promptRef = child:FindFirstChild("PromptRef")
				local prompt = promptRef and promptRef:IsA("ObjectValue") and promptRef.Value
				if prompt and prompt:IsA("ProximityPrompt") then
					seenPromptMap[prompt] = true

					local parentPart = child.Adornee or prompt.Parent
					local promptPos = getInstancePosition(parentPart)
					local dist = (refPos and promptPos) and math.round((refPos - promptPos).Magnitude * 10) / 10 or nil

					table.insert(results, {
						path = prompt:GetFullName(),
						name = prompt.Name,
						action_text = prompt.ActionText,
						object_text = prompt.ObjectText,
						hold_duration = prompt.HoldDuration,
						max_activation_distance = prompt.MaxActivationDistance,
						enabled = prompt.Enabled,
						key_code = prompt.KeyboardKeyCode.Name,
						distance = dist,
						is_currently_displayed = true,
						source = "CustomProximityPrompts",
						parent_path = parentPart and parentPart:GetFullName(),
						requires_line_of_sight = prompt.RequiresLineOfSight,
					})
				end
			end
		end
	end

	-- 2. Also scan Workspace for any other active/enabled prompts within distance
	for _, prompt in ipairs(Workspace:GetDescendants()) do
		if prompt:IsA("ProximityPrompt") and not seenPromptMap[prompt] then
			local parentPart = prompt.Parent
			local promptPos = getInstancePosition(parentPart)

			local dist = nil
			if refPos and promptPos then
				dist = (refPos - promptPos).Magnitude
			end

			local withinDist = true
			if dist and dist > maxDist then
				withinDist = false
			end

			if withinDist then
				table.insert(results, {
					path = prompt:GetFullName(),
					name = prompt.Name,
					action_text = prompt.ActionText,
					object_text = prompt.ObjectText,
					hold_duration = prompt.HoldDuration,
					max_activation_distance = prompt.MaxActivationDistance,
					enabled = prompt.Enabled,
					key_code = prompt.KeyboardKeyCode.Name,
					distance = dist and math.round(dist * 10) / 10 or nil,
					is_currently_displayed = false,
					source = "WorkspaceScan",
					parent_path = parentPart and parentPart:GetFullName(),
					requires_line_of_sight = prompt.RequiresLineOfSight,
				})
			end
		end
	end

	-- Sort: currently displayed prompts first, then by distance
	table.sort(results, function(a, b)
		if a.is_currently_displayed ~= b.is_currently_displayed then
			return a.is_currently_displayed == true
		end
		return (a.distance or 9999) < (b.distance or 9999)
	end)

	return {
		success = true,
		count = #results,
		currently_displayed_count = (function()
			local c = 0
			for _, r in ipairs(results) do if r.is_currently_displayed then c += 1 end end
			return c
		end)(),
		prompts = results,
	}
end

function CommandHandlers.trigger_prompt(params)
	local promptPath = params.prompt_path or params.path
	if not promptPath then return nil, "prompt_path parameter is required" end

	local prompt = resolvePath(promptPath)
	if not prompt or not prompt:IsA("ProximityPrompt") then
		return nil, "Instance at path is not a ProximityPrompt: " .. tostring(promptPath)
	end

	local holdTime = tonumber(params.duration) or prompt.HoldDuration or 0.5
	local success = false
	local methodUsed = "fireproximityprompt"

	-- Method 1: fireproximityprompt (if available)
	pcall(function()
		if fireproximityprompt then
			fireproximityprompt(prompt, holdTime)
			success = true
		end
	end)

	-- Method 2: VirtualInputManager
	if not success then
		local vim = nil
		pcall(function() vim = game:GetService("VirtualInputManager") end)
		if vim and prompt.KeyboardKeyCode then
			methodUsed = "VirtualInputManager"
			pcall(function()
				vim:SendKeyEvent(true, prompt.KeyboardKeyCode, false, nil)
				task.wait(holdTime + 0.15)
				vim:SendKeyEvent(false, prompt.KeyboardKeyCode, false, nil)
				success = true
			end)
		end
	end

	-- Method 3: Script-level fallback
	if not success then
		methodUsed = "InputHoldSim"
		pcall(function()
			prompt:InputHoldBegin()
			task.wait(holdTime + 0.1)
			prompt:InputHoldEnd()
			success = true
		end)
	end

	return {
		success = success,
		prompt = prompt:GetFullName(),
		action_text = prompt.ActionText,
		object_text = prompt.ObjectText,
		method = methodUsed,
		hold_time = holdTime,
	}
end

function CommandHandlers.simulate_input(params)
	local vim = nil
	local okVim = pcall(function() vim = game:GetService("VirtualInputManager") end)
	if not okVim or not vim then
		return nil, "VirtualInputManager is not available in this environment"
	end

	local action = params.action
	if not action then return nil, "action parameter is required" end

	if action == "key_press" then
		local keyName = params.key or "Space"
		local keyEnum = Enum.KeyCode[keyName]
		if not keyEnum then return nil, "Invalid KeyCode: " .. tostring(keyName) end
		local dur = tonumber(params.duration) or 0.05
		vim:SendKeyEvent(true, keyEnum, false, nil)
		if dur > 0 then task.wait(dur) end
		vim:SendKeyEvent(false, keyEnum, false, nil)
		return { success = true, action = "key_press", key = keyName, duration = dur }

	elseif action == "key_down" then
		local keyName = params.key or "W"
		local keyEnum = Enum.KeyCode[keyName]
		if not keyEnum then return nil, "Invalid KeyCode: " .. tostring(keyName) end
		vim:SendKeyEvent(true, keyEnum, false, nil)
		return { success = true, action = "key_down", key = keyName }

	elseif action == "key_up" then
		local keyName = params.key or "W"
		local keyEnum = Enum.KeyCode[keyName]
		if not keyEnum then return nil, "Invalid KeyCode: " .. tostring(keyName) end
		vim:SendKeyEvent(false, keyEnum, false, nil)
		return { success = true, action = "key_up", key = keyName }

	elseif action == "mouse_click" then
		local x = tonumber(params.x) or 0
		local y = tonumber(params.y) or 0
		local button = (params.button == "Right") and 1 or 0
		local dur = tonumber(params.duration) or 0.05
		vim:SendMouseButtonEvent(x, y, button, true, nil, 1)
		if dur > 0 then task.wait(dur) end
		vim:SendMouseButtonEvent(x, y, button, false, nil, 1)
		return { success = true, action = "mouse_click", x = x, y = y, button = button }

	elseif action == "mouse_move" then
		local x = tonumber(params.x) or 0
		local y = tonumber(params.y) or 0
		vim:SendMouseMoveEvent(x, y, nil)
		return { success = true, action = "mouse_move", x = x, y = y }

	elseif action == "mouse_drag" then
		local x1 = tonumber(params.from_x or params.x) or 0
		local y1 = tonumber(params.from_y or params.y) or 0
		local x2 = tonumber(params.to_x) or x1
		local y2 = tonumber(params.to_y) or y1
		local steps = math.max(2, math.floor(tonumber(params.steps) or 10))
		local dur = tonumber(params.duration) or 0.3
		local stepDelay = dur / steps

		vim:SendMouseMoveEvent(x1, y1, nil)
		vim:SendMouseButtonEvent(x1, y1, 0, true, nil, 1)
		for i = 1, steps do
			local alpha = i / steps
			local cx = x1 + (x2 - x1) * alpha
			local cy = y1 + (y2 - y1) * alpha
			vim:SendMouseMoveEvent(cx, cy, nil)
			task.wait(stepDelay)
		end
		vim:SendMouseButtonEvent(x2, y2, 0, false, nil, 1)
		return { success = true, action = "mouse_drag", from = {x1, y1}, to = {x2, y2}, duration = dur }
	else
		return nil, "Unknown input action: " .. tostring(action)
	end
end

function CommandHandlers.input_sequence(params)
	local vim = nil
	pcall(function() vim = game:GetService("VirtualInputManager") end)
	if not vim then
		return nil, "VirtualInputManager is not available"
	end

	local sequence = params.sequence
	if type(sequence) ~= "table" or #sequence == 0 then
		return nil, "sequence array is required"
	end

	local executedCount = 0
	for _, step in ipairs(sequence) do
		local action = step.action
		if action == "wait" or action == "delay" then
			local dur = tonumber(step.duration or step.delay) or 0.1
			task.wait(dur)
		elseif action == "key_press" then
			local k = Enum.KeyCode[step.key]
			if k then
				vim:SendKeyEvent(true, k, false, nil)
				task.wait(tonumber(step.duration) or 0.05)
				vim:SendKeyEvent(false, k, false, nil)
			end
		elseif action == "key_down" then
			local k = Enum.KeyCode[step.key]
			if k then vim:SendKeyEvent(true, k, false, nil) end
		elseif action == "key_up" then
			local k = Enum.KeyCode[step.key]
			if k then vim:SendKeyEvent(false, k, false, nil) end
		elseif action == "mouse_click" then
			local x = tonumber(step.x) or 0
			local y = tonumber(step.y) or 0
			local btn = (step.button == "Right") and 1 or 0
			vim:SendMouseButtonEvent(x, y, btn, true, nil, 1)
			task.wait(tonumber(step.duration) or 0.05)
			vim:SendMouseButtonEvent(x, y, btn, false, nil, 1)
		elseif action == "mouse_move" then
			vim:SendMouseMoveEvent(tonumber(step.x) or 0, tonumber(step.y) or 0, nil)
		end

		executedCount += 1
		if step.post_delay then
			task.wait(tonumber(step.post_delay))
		end
	end

	return {
		success = true,
		executed_steps = executedCount,
	}
end

function CommandHandlers.click_ui_element(params)
	local targetPath = params.path
	local targetText = params.text
	local player = Players.LocalPlayer or Players:GetPlayers()[1]
	if not player then return nil, "No player found" end
	local playerGui = player:FindFirstChild("PlayerGui")
	if not playerGui then return nil, "PlayerGui not found" end

	local targetBtn = nil
	if targetPath then
		targetBtn = resolvePath(targetPath)
	elseif targetText then
		for _, desc in ipairs(playerGui:GetDescendants()) do
			if desc:IsA("TextButton") or desc:IsA("TextLabel") or desc:IsA("ImageButton") then
				local text = desc:FindFirstChild("Text") or (desc:IsA("TextButton") and desc.Text) or (desc:IsA("TextLabel") and desc.Text)
				if text and string.find(string.lower(tostring(text)), string.lower(targetText)) then
					targetBtn = desc:FindFirstAncestorWhichIsA("GuiButton") or desc
					break
				end
			end
		end
	end

	if not targetBtn or not targetBtn:IsA("GuiObject") then
		return nil, "UI Button/Element not found"
	end

	local absPos = targetBtn.AbsolutePosition
	local absSize = targetBtn.AbsoluteSize
	local centerX = absPos.X + absSize.X / 2
	local centerY = absPos.Y + absSize.Y / 2

	local vim = nil
	pcall(function() vim = game:GetService("VirtualInputManager") end)
	if vim then
		vim:SendMouseButtonEvent(centerX, centerY, 0, true, nil, 1)
		task.wait(0.05)
		vim:SendMouseButtonEvent(centerX, centerY, 0, false, nil, 1)
	end

	return {
		success = true,
		element = targetBtn:GetFullName(),
		center_x = math.floor(centerX),
		center_y = math.floor(centerY),
	}
end

function CommandHandlers.world_to_screen(params)
	local camera = Workspace.CurrentCamera
	if not camera then return nil, "CurrentCamera not found" end

	local targetPos = nil
	if params.path then
		local inst = resolvePath(params.path)
		targetPos = getInstancePosition(inst)
	elseif params.position then
		targetPos = Vector3.new(params.position.X or params.position.x or 0, params.position.Y or params.position.y or 0, params.position.Z or params.position.z or 0)
	end

	if not targetPos then return nil, "Valid path or position required" end

	local screenPos, onScreen = camera:WorldToViewportPoint(targetPos)
	return {
		success = true,
		x = math.floor(screenPos.X),
		y = math.floor(screenPos.Y),
		depth = math.floor(screenPos.Z * 10) / 10,
		on_screen = onScreen,
	}
end

function CommandHandlers.look_at(params)
	local camera = Workspace.CurrentCamera
	if not camera then return nil, "CurrentCamera not found" end

	local targetPos = nil
	if params.target then
		local inst = resolvePath(params.target)
		targetPos = getInstancePosition(inst)
	elseif params.x and params.y and params.z then
		targetPos = Vector3.new(params.x, params.y, params.z)
	end

	if not targetPos then return nil, "Valid target instance or coordinates required" end

	camera.CFrame = CFrame.lookAt(camera.CFrame.Position, targetPos)
	return {
		success = true,
		camera_cframe = serializeValue(camera.CFrame),
	}
end

function CommandHandlers.set_camera(params)
	local camera = Workspace.CurrentCamera
	if not camera then return nil, "CurrentCamera not found" end

	if params.cframe then
		local cf = deserializeValue(params.cframe)
		if cf then camera.CFrame = cf end
	end
	if params.fov then
		camera.FieldOfView = tonumber(params.fov)
	end
	return {
		success = true,
		camera_cframe = serializeValue(camera.CFrame),
		fov = camera.FieldOfView,
	}
end

function CommandHandlers.teleport(params)
	local player = nil
	if params.player_name then
		player = Players:FindFirstChild(params.player_name)
	else
		player = Players.LocalPlayer or Players:GetPlayers()[1]
	end
	if not player then return nil, "Player not found" end
	local char = player.Character
	if not char then return nil, "Player character not spawned" end
	local root = char:FindFirstChild("HumanoidRootPart") or char.PrimaryPart
	if not root then return nil, "Character HumanoidRootPart not found" end

	local targetCFrame = nil
	if params.target then
		local inst = resolvePath(params.target)
		local _, cf = getInstancePosition(inst)
		targetCFrame = cf
	elseif params.position then
		targetCFrame = CFrame.new(params.position.X or params.position.x or 0, params.position.Y or params.position.y or 0, params.position.Z or params.position.z or 0)
	end

	if not targetCFrame then return nil, "Valid target path or position required" end

	local ox = tonumber(params.offset_x) or 0
	local oy = tonumber(params.offset_y) or 0
	local oz = tonumber(params.offset_z) or 0
	local finalCFrame = targetCFrame * CFrame.new(ox, oy, oz)

	char:PivotTo(finalCFrame)
	return {
		success = true,
		player = player.Name,
		new_cframe = serializeValue(finalCFrame),
	}
end

function CommandHandlers.equip_tool(params)
	local toolName = params.tool_name
	if not toolName then return nil, "tool_name parameter is required" end

	local player = Players.LocalPlayer or Players:GetPlayers()[1]
	if not player then return nil, "Player not found" end
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not hum then return nil, "Humanoid not found" end

	-- Check if already equipped
	local equipped = char:FindFirstChildOfClass("Tool")
	if equipped and string.find(string.lower(equipped.Name), string.lower(toolName)) then
		return { success = true, equipped = equipped.Name, already_equipped = true }
	end

	-- Look in Backpack
	local backpack = player:FindFirstChild("Backpack")
	if not backpack then return nil, "Backpack not found" end

	local targetTool = nil
	for _, t in ipairs(backpack:GetChildren()) do
		if t:IsA("Tool") and string.find(string.lower(t.Name), string.lower(toolName)) then
			targetTool = t
			break
		end
	end

	if not targetTool then
		return nil, "Tool '" .. tostring(toolName) .. "' not found in Backpack or Character"
	end

	hum:EquipTool(targetTool)
	return {
		success = true,
		equipped = targetTool.Name,
	}
end

function CommandHandlers.get_playtest_mode(params)
	local isRunning = RunService:IsRunning()
	local isEdit = RunService:IsEdit()
	local isServer = RunService:IsServer()
	local isClient = RunService:IsClient()

	local modeStr = "Unknown"
	if isEdit then
		modeStr = "Edit"
	elseif isServer and isClient then
		modeStr = "PlaySolo"
	elseif isServer and not isClient then
		modeStr = "Server"
	elseif isClient and not isServer then
		modeStr = "Client"
	end

	local sts = nil
	local customArg = nil
	pcall(function()
		sts = game:GetService("StudioTestService")
		if sts and sts.GetTestArgs then
			customArg = sts:GetTestArgs()
		end
	end)

	return {
		success = true,
		mode = modeStr,
		is_running = isRunning,
		is_edit = isEdit,
		is_server = isServer,
		is_client = isClient,
		test_args = customArg,
		game_time = math.floor(workspace.DistributedGameTime * 10) / 10,
	}
end

function CommandHandlers.get_player_state(params)
	local isRunning = RunService:IsRunning()
	local isEdit = RunService:IsEdit()
	local isServer = RunService:IsServer()
	local isClient = RunService:IsClient()
	local modeStr = if isEdit then "Edit" elseif isServer and isClient then "PlaySolo" elseif isServer then "Server" elseif isClient then "Client" else "Unknown"

	local player = Players.LocalPlayer or Players:GetPlayers()[1]
	if not player then
		return {
			success = true,
			playtest_mode = modeStr,
			is_running = isRunning,
			player_name = nil,
			message = "No active player (Studio may be in Edit Mode)",
		}
	end

	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local root = char and (char:FindFirstChild("HumanoidRootPart") or char.PrimaryPart)

	local equippedTool = char and char:FindFirstChildOfClass("Tool")
	local backpackTools = {}
	local backpack = player:FindFirstChild("Backpack")
	if backpack then
		for _, t in ipairs(backpack:GetChildren()) do
			if t:IsA("Tool") then table.insert(backpackTools, t.Name) end
		end
	end

	local attributes = {}
	if char then
		for k, v in pairs(char:GetAttributes()) do
			attributes[k] = serializeValue(v)
		end
	end

	return {
		success = true,
		playtest_mode = modeStr,
		is_running = isRunning,
		player_name = player.Name,
		team = player.Team and player.Team.Name or "None",
		health = hum and hum.Health or 0,
		max_health = hum and hum.MaxHealth or 0,
		position = root and serializeValue(root.Position) or nil,
		equipped_tool = equippedTool and equippedTool.Name or nil,
		backpack_tools = backpackTools,
		character_attributes = attributes,
	}
end

function CommandHandlers.chat(params)
	local message = params.message
	if not message or message == "" then return nil, "message parameter is required" end

	local player = Players.LocalPlayer or Players:GetPlayers()[1]
	if not player then return nil, "Player not found" end

	local sent = false
	-- Try TextChatService
	local okTCS, tcs = pcall(function() return game:GetService("TextChatService") end)
	if okTCS and tcs and tcs.ChatVersion == Enum.ChatVersion.TextChatService then
		local generalChannel = tcs:FindFirstChild("TextChannels", true) and tcs:FindFirstChild("TextChannels"):FindFirstChild("RBXGeneral")
		if generalChannel then
			generalChannel:SendAsync(message)
			sent = true
		end
	end

	-- Fallback to legacy Chat
	if not sent then
		local okChat, chatSvc = pcall(function() return game:GetService("Chat") end)
		if okChat and chatSvc and player.Character and player.Character:FindFirstChild("Head") then
			chatSvc:Chat(player.Character.Head, message, Enum.ChatColor.White)
			sent = true
		end
	end

	return {
		success = sent,
		message = message,
	}
end

function CommandHandlers.wait_for(params)
	local targetPath = params.path
	local attrName = params.attribute
	local propName = params.property
	local expected = params.expected_value
	local timeout = tonumber(params.timeout) or 10.0

	local inst = resolvePath(targetPath)
	if not inst then return nil, "Instance not found: " .. tostring(targetPath) end

	local startTime = tick()
	local matched = false
	local lastVal = nil

	while (tick() - startTime) < timeout do
		if attrName then
			lastVal = inst:GetAttribute(attrName)
		elseif propName then
			pcall(function() lastVal = inst[propName] end)
		end

		if expected == nil then
			if lastVal ~= nil then matched = true; break end
		elseif lastVal == expected then
			matched = true
			break
		end
		task.wait(0.2)
	end

	return {
		success = matched,
		matched = matched,
		current_value = serializeValue(lastVal),
		elapsed = math.floor((tick() - startTime) * 10) / 10,
	}
end

function CommandHandlers.start_playtest(params)
	local sts = nil
	pcall(function() sts = game:GetService("StudioTestService") end)
	if not sts then return nil, "StudioTestService not available" end

	local ok, res = pcall(function()
		return sts:ExecutePlayModeAsync("MCPPlaytest")
	end)
	return {
		success = ok,
		result = tostring(res),
	}
end

function CommandHandlers.stop_playtest(params)
	local sts = nil
	pcall(function() sts = game:GetService("StudioTestService") end)
	if sts and sts.StopPlaytest then
		pcall(function() sts:StopPlaytest() end)
		return { success = true }
	end
	return { success = false, message = "StopPlaytest API not available directly" }
end

------------------------------------------------------------------------
-- WebSocket Connection
------------------------------------------------------------------------
local function processMessage(messageData)
	local success, message = pcall(function()
		return HttpService:JSONDecode(messageData)
	end)

	if not success then
		warn("[MCP Bridge] Failed to decode message:", messageData)
		return
	end

	-- Handle pong
	if message.type == "pong" then
		return
	end

	local commandId = message.id
	local command = message.command
	local params = message.params or {}

	if not commandId or not command then
		warn("[MCP Bridge] Invalid command message (missing id or command)")
		return
	end

	-- Context filtering
	local targetContext = message.target_context or (params and (params.target_context or params.context))
	local myContext = getContextRole()
	if targetContext and targetContext ~= "any" and targetContext ~= "auto" then
		if targetContext:lower() ~= myContext:lower() then
			-- Message intended for another context (e.g. Server vs Client); ignore cleanly
			return
		end
	end

	-- Execute command
	local handler = CommandHandlers[command]
	local response

	if handler then
		local cmdSuccess, resultOrErr, errMsg = pcall(handler, params)
		if cmdSuccess then
			if resultOrErr then
				response = {
					id = commandId,
					data = resultOrErr,
				}
			else
				response = {
					id = commandId,
					error = errMsg or "Command returned no result",
				}
			end
		else
			response = {
				id = commandId,
				error = "Command execution error: " .. tostring(resultOrErr),
			}
		end
	else
		response = {
			id = commandId,
			error = string.format("Unknown command: '%s'. Available: ls, ls_descendants, ls_summary, get_properties, get_by_tag, search, get_viewport_size, verify_script, create_script, get_ui_tree, get_ui_design_properties, inspect_ui_component, get_ui_palette, mount_story, unmount_story, list_mounted_stories, unmount_all_stories, execute_code, get_output_logs, set_properties, set_attribute, get_attributes, get_selection, set_selection, focus_on_selection, get_active_proximity_prompts, trigger_prompt, simulate_input, input_sequence, click_ui_element, world_to_screen, look_at, set_camera, teleport, equip_tool, get_player_state, get_playtest_mode, chat, wait_for, start_playtest, stop_playtest", command),
		}
	end

	if response then
		response.context = myContext
	end

	-- Send response back
	if wsClient then
		local encodeSuccess, jsonResponse = pcall(function()
			return HttpService:JSONEncode(response)
		end)
		if encodeSuccess then
			pcall(function()
				wsClient:Send(jsonResponse)
			end)
		else
			-- Encoding failed - send error
			pcall(function()
				wsClient:Send(HttpService:JSONEncode({
					id = commandId,
					error = "Failed to serialize response: " .. tostring(jsonResponse),
				}))
			end)
		end
	end
end

local function logStatus(statusKey, message)
	if lastLoggedStatus ~= statusKey then
		lastLoggedStatus = statusKey
		if message then
			print(message .. " [" .. getContextRole():upper() .. "]")
		end
	end
end

local function connectWebSocket()
	if isConnected or isConnecting or wsClient ~= nil or not pluginActive then
		return
	end

	isConnecting = true
	connectionAttemptTime = os.clock()

	local success, client = pcall(function()
		return HttpService:CreateWebStreamClient(Enum.WebStreamClientType.WebSocket, {
			Url = WS_URL,
		})
	end)

	isConnecting = false

	if not pluginActive then
		if success and client then
			pcall(function() client:Close() end)
		end
		return
	end

	if not success or not client then
		logStatus("offline", "[MCP Bridge] ⏳ Connection attempt failed. Ensure Allow HTTP Requests is enabled in Game Settings -> Security.")
		return
	end

	local currentClient = client
	wsClient = currentClient

	local messageConn = nil
	local closedConn = nil

	local function cleanup()
		if messageConn then
			messageConn:Disconnect()
			messageConn = nil
		end
		if closedConn then
			closedConn:Disconnect()
			closedConn = nil
		end
		if wsClient == currentClient then
			wsClient = nil
		end
	end

	-- Handle disconnection
	closedConn = currentClient.Closed:Connect(function()
		cleanup()
		local wasConnected = isConnected
		isConnected = false

		if wasConnected then
			logStatus("disconnected", "[MCP Bridge] ❌ Disconnected from server")
		end
	end)

	-- Handle incoming messages
	messageConn = currentClient.MessageReceived:Connect(function(message)
		if not isConnected then
			isConnected = true
			logStatus("connected", "[MCP Bridge] ✅ Connected to " .. WS_URL)
		end
		processMessage(message)
	end)

	-- Send initial register after slight delay to announce context
	task.delay(0.2, function()
		if wsClient == currentClient and not isConnected then
			pcall(function()
				currentClient:Send(HttpService:JSONEncode({
					type = "register",
					context = getContextRole(),
				}))
			end)
		end
	end)

	task.delay(1.0, function()
		if wsClient == currentClient and not isConnected then
			pcall(function()
				currentClient:Send(HttpService:JSONEncode({
					type = "ping",
					context = getContextRole(),
				}))
			end)
		end
	end)
end

------------------------------------------------------------------------
-- Auto-reconnect loop
------------------------------------------------------------------------
local reconnectThread = nil

local function startReconnectLoop()
	if reconnectThread then
		return
	end

	reconnectThread = task.spawn(function()
		while pluginActive do
			if not isConnected then
				if wsClient and (os.clock() - connectionAttemptTime > 10) then
					local stale = wsClient
					wsClient = nil
					pcall(function() stale:Close() end)
				end
				if wsClient == nil and not isConnecting then
					connectWebSocket()
				end
			end
			task.wait(RECONNECT_DELAY)
		end
	end)
end

local function stopReconnectLoop()
	if reconnectThread then
		task.cancel(reconnectThread)
		reconnectThread = nil
	end
end

------------------------------------------------------------------------
-- Plugin Toggle
------------------------------------------------------------------------
local function activate()
	pluginActive = true
	toggleButton:SetActive(true)
	connectWebSocket()
	startReconnectLoop()
end

local function deactivate()
	pluginActive = false
	toggleButton:SetActive(false)
	stopReconnectLoop()

	pcall(function()
		CommandHandlers.unmount_all_stories({})
	end)

	if wsClient then
		local toClose = wsClient
		wsClient = nil
		isConnected = false
		pcall(function()
			toClose:Close()
		end)
	end

	logStatus("deactivated", "[MCP Bridge] 🛑 Plugin deactivated")
end

toggleButton.Click:Connect(function()
	if pluginActive then
		deactivate()
	else
		activate()
	end
end)

------------------------------------------------------------------------
-- Auto-start on plugin load
------------------------------------------------------------------------
activate()

-- Cleanup on plugin unload
plugin.Unloading:Connect(function()
	deactivate()
end)
