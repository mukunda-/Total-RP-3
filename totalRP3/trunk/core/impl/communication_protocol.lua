--*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*
-- Total RP 3 Addon Communication protocol
-- This is a regular protocol based on layers 1 & 3 & 4 & 5 from the ISO-OSI model.
--*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*

-- Ideas:
-- TODO: compression ?
-- TODO: 255 base encoding numbers ?

-- function definition
local handlePacketsIn;
local handleStructureIn;
local receiveObject;

--*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*
-- LAYER 0 : CONNECTION LAYER
-- Makes connection with Wow communication functions, or debug functions
--*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*

local wowCom_prefix = "TRP3";
local connection_id = 1; -- 1 = Wow, 2 = localhost, 3 = print
TRP3_COMM_INTERFACE = {
	WOW = 1,
	DIRECT_RELAY = 2,
	DIRECT_PRINT = 3
};

-- This is the main communication interface, using ChatThrottleLib to
-- avoid being kicked by the server when sending a lot of data.
local function wowCommunicationInterface(packet, target, priority)
	ChatThrottleLib:SendAddonPackage(priority or "BULK", wowCom_prefix, packet, "WHISPER", target);
end

-- A "direct relay" (like localhost) communication interface, used for development purpose.
-- Any message sent to this communication interface is directly rerouted to the user itself.
-- Note that the messages are not really sent.
local function directRelayInterface(packet, target)
	handlePacketsIn(packet, target);
end

-- This communication interface print all sent message to the chat frame.
-- Note that the messages are not really sent.
local function directPrint(packet, target, priority)
	print("Message to: "..tostring(target).." - Priority: "..tostring(priority).." - Message:\n" .. tostring(packet));
end

-- Returns the function reference to be used as communication interface.
local function getCommunicationInterface()
	if connection_id == TRP3_COMM_INTERFACE.WOW then return wowCommunicationInterface end
	if connection_id == TRP3_COMM_INTERFACE.DIRECT_RELAY then return directRelayInterface end
	if connection_id == TRP3_COMM_INTERFACE.DIRECT_PRINT then return directPrint end
end

-- Changes the communication interface to use
function TRP3_setCommunicationInterfaceId(id)
	connection_id = id;
end

--*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*
-- LAYER 1 : PACKET LAYER
-- Packet sending and receiving
-- Handles packet sequences
--*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*
-- 254 - TRP3(4) - MESSAGE_ID(2) - control character(1)
local AVAILABLE_CHARACTERS = 246;
local NEXT_PACKET_PREFIX = 1;
local LAST_PACKET_PREFIX = 2;
local PACKETS_RECEPTOR = {};

-- Send each packet to the current communication interface.
local function handlePacketsOut(messageID, packets, target, priority)
	if #packets ~= 0 then
		for index, packet in pairs(packets) do
			assert(packet:len() <= AVAILABLE_CHARACTERS, "Too long packet !");
			local control = string.char(NEXT_PACKET_PREFIX);
			if index == #packets then
				control = string.char(LAST_PACKET_PREFIX);
			end
			getCommunicationInterface()(messageID..control..packet, target, priority);
		end
	end
end

local function savePacket(sender, messageID, packet)
	if not PACKETS_RECEPTOR[sender] then
		PACKETS_RECEPTOR[sender] = {};
	end
	if not PACKETS_RECEPTOR[sender][messageID] then
		PACKETS_RECEPTOR[sender][messageID] = {};
	end
	tinsert(PACKETS_RECEPTOR[sender][messageID], packet);
end

local function getPackets(sender, messageID)
	assert(PACKETS_RECEPTOR[sender] and PACKETS_RECEPTOR[sender][messageID], "No stored packets from "..sender.." for structure "..messageID);
	return PACKETS_RECEPTOR[sender][messageID];
end

local function endPacket(sender, messageID)
	assert(PACKETS_RECEPTOR[sender] and PACKETS_RECEPTOR[sender][messageID], "No stored packets from "..sender.." for structure "..messageID);
	wipe(PACKETS_RECEPTOR[sender][messageID]);
	PACKETS_RECEPTOR[sender][messageID] = nil;
end

handlePacketsIn = function(packet, sender)
	local messageID = packet:sub(1, 2);
	local control = packet:sub(3, 3);
	savePacket(sender, messageID, packet:sub(4));
	if control:byte(1) == LAST_PACKET_PREFIX then
		handleStructureIn(getPackets(sender, messageID), sender);
		endPacket(sender, messageID);
	end
end

--*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*
-- LAYER 2 : MESSAGE LAYER
-- Structure-to-Message serialization / deserialization
-- Message cutting in packets / Message reconstitution
--*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*

local MESSAGE_ID_1 = 0;
local MESSAGE_ID_2 = 0;
local MESSAGE_ID = string.char(MESSAGE_ID_1, MESSAGE_ID_2);

-- Message IDs are 256 base number encoded on 2 chars (256*256 = 65536 available Message IDs)
local function getMessageIDAndIncrement()
	local toReturn = MESSAGE_ID;
	MESSAGE_ID_2 = MESSAGE_ID_2 + 1;
	if MESSAGE_ID_2 > 255 then
		MESSAGE_ID_2 = 0;
		MESSAGE_ID_1 = MESSAGE_ID_1 + 1;
		if MESSAGE_ID_1 > 255 then
			MESSAGE_ID_1 = 0;
		end
	end
	MESSAGE_ID = string.char(MESSAGE_ID_1, MESSAGE_ID_2);
	return toReturn;
end

-- Convert structure to message, cut message in packets.
local function handleStructureOut(structure, target, priority)
	local message = TRP3_GetAddon():Serialize(structure);
	local messageID = getMessageIDAndIncrement();
	local messageSize = message:len();
	local packetTab = {};
	local index = 0;
	while index < messageSize do
		tinsert(packetTab, message:sub(index, index + AVAILABLE_CHARACTERS));
		index = index + AVAILABLE_CHARACTERS + 1;
	end
	handlePacketsOut(messageID, packetTab, target, priority);
end

-- Reassemble the message based on the packets, and deserialize it.
handleStructureIn = function(packets, sender)
	local message = "";
	for index, packet in pairs(packets) do
		message = message..packet;
	end
	local status, structure = TRP3_GetAddon():Deserialize(message);
	if status then
		receiveObject(structure, sender);
	end
end

--*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*
-- LAYER 3 : STRUCTURE LAYER
-- "What to do with the structure received / to send ?"
--*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*

local PREFIX_REGISTRATION = {};

-- Register a function to callback when receiving a object attached to the given prefix
function TRP3_RegisterProtocolPrefix(prefix, callback)
	assert(prefix and callback and type(callback) == "function", "Usage: prefix, callback");
	if PREFIX_REGISTRATION[prefix] == nil then
		PREFIX_REGISTRATION[prefix] = {};
	end
	tinsert(PREFIX_REGISTRATION[prefix], callback);
end

-- Send a object to a player
-- Prefix must have been registered before use this function
-- The object can be any lua type (numbers, strings, tables, but NOT functions or userdatas)
-- Priority is optional ("Bulk" by default)
function TRP3_SendObject(prefix, object, target, priority)
	assert(PREFIX_REGISTRATION[prefix] ~= nil, "Unregistered prefix: "..prefix);
	local structure = {prefix, object};
	handleStructureOut(structure, target, priority);
end

-- Receive a structure from a player (sender)
-- Call any callback registered for this prefix.
-- Structure[1] contains the prefix, structure[2] contains the object
receiveObject = function(structure, sender)
	if type(structure) == "table" and #structure == 2 then
		local prefix = structure[1];
		if PREFIX_REGISTRATION[prefix] then
			for _, callback in pairs(PREFIX_REGISTRATION[prefix]) do
				callback(structure[2], sender);
			end
		end
	end
end

-- Estimate the number of packet needed to send a object.
function TRP3_EstimateStructureLoad(object)
	assert(object, "Object nil");
	return math.ceil((#(TRP3_GetAddon():Serialize({"MOCK", object}))) / AVAILABLE_CHARACTERS);
end