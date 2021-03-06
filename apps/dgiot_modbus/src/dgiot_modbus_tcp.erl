%%--------------------------------------------------------------------
%% Copyright (c) 2020-2021 DGIOT Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------
-module(dgiot_modbus_tcp).
-author("stoneliu").
-include("dgiot_modbus.hrl").
-include_lib("dgiot/include/dgiot_socket.hrl").
-include_lib("dgiot/include/logger.hrl").

-define(MAX_BUFF_SIZE, 1024).

-export([
    get_deviceid/2,
    start/2
]).

%% TCP callback
-export([init/1, handle_info/2, handle_cast/2, handle_call/3, terminate/2, code_change/3]).

start(Port, State) ->
    dgiot_tcp_server:child_spec(?MODULE, dgiot_utils:to_int(Port), State).

%% =======================
%% {ok, State} | {stop, Reason}
%%init(TCPState) ->
%%    erlang:send_after(5 * 1000, self(), login),.
%%    {ok, TCPState}.

init(#tcp{state = #state{id = ChannelId}} = TCPState) ->
    ?LOG(info, "ChannelId ~p", [ChannelId]),
    case dgiot_bridge:get_products(ChannelId) of
        {ok, _TYPE, _ProductIds} ->
            {ok, TCPState};
        {error, not_find} ->
            {stop, not_find_channel}
    end.

%% 9C A5 25 CD 00 DB
%% 11 04 02 06 92 FA FE
handle_info({tcp, Buff}, #tcp{socket = Socket, state = #state{id = ChannelId, devaddr = <<>>, head = Head, len = Len, product = ProductId} = State} = TCPState) ->
    dgiot_bridge:send_log(ChannelId, "DTU revice from  ~p", [dgiot_utils:binary_to_hex(Buff)]),
    DTUIP = dgiot_utils:get_ip(Socket),
    DtuAddr = dgiot_utils:binary_to_hex(Buff),
    List = dgiot_utils:to_list(DtuAddr),
    List1 = dgiot_utils:to_list(Buff),
    #{<<"objectId">> := DeviceId} =
        dgiot_parse:get_objectid(<<"Device">>, #{<<"product">> => ProductId, <<"devaddr">> => DtuAddr}),
    case re:run(DtuAddr, Head, [{capture, first, list}]) of
        {match, [Head]} when length(List) == Len ->
            {DevId, Devaddr} =
                case create_device(DeviceId, ProductId, DtuAddr, DTUIP) of
                    {<<>>, <<>>} ->
                        {<<>>, <<>>};
                    {DevId1, Devaddr1} ->
                        {DevId1, Devaddr1}
                end,
            {noreply, TCPState#tcp{buff = <<>>, state = State#state{devaddr = Devaddr, deviceId = DevId}}};
        _Error ->
            case re:run(Buff, Head, [{capture, first, list}]) of
                {match, [Head]} when length(List1) == Len ->
                    create_device(DeviceId, ProductId, Buff, DTUIP),
                    {noreply, TCPState#tcp{buff = <<>>, state = State#state{devaddr = Buff}}};
                Error1 ->
                    ?LOG(info, "Error1 ~p Buff ~p ", [Error1, dgiot_utils:to_list(Buff)]),
                    {noreply, TCPState#tcp{buff = <<>>}}
            end
    end;

handle_info({tcp, Buff}, #tcp{state = #state{id = ChannelId, devaddr = DtuAddr, env = #{product := ProductId, pn := Pn, di := Di}, product = DtuProductId} = State} = TCPState) ->
    dgiot_bridge:send_log(ChannelId, "revice from  ~p", [dgiot_utils:binary_to_hex(Buff)]),
    <<H:8, L:8>> = dgiot_utils:hex_to_binary(modbus_rtu:is16(Di)),
    <<Sh:8, Sl:8>> = dgiot_utils:hex_to_binary(modbus_rtu:is16(Pn)),
    case modbus_rtu:parse_frame(Buff, [], #{
        <<"dtuproduct">> => ProductId,
        <<"channel">> => ChannelId,
        <<"dtuaddr">> => DtuAddr,
        <<"slaveId">> => Sh * 256 + Sl,
        <<"address">> => H * 256 + L}) of
        {_, Things} ->
            NewTopic = <<"thing/", DtuProductId/binary, "/", DtuAddr/binary, "/post">>,
            dgiot_bridge:send_log(ChannelId, "end to_task: ~p: ~p ~n", [NewTopic, jsx:encode(Things)]),
            dgiot_mqtt:publish(DtuAddr, NewTopic, jsx:encode(Things));
        Other ->
            ?LOG(info, "Other ~p", [Other]),
            pass
    end,
    {noreply, TCPState#tcp{buff = <<>>, state = State#state{env = <<>>}}};

handle_info({deliver, _Topic, Msg}, #tcp{state = #state{id = ChannelId} = State} = TCPState) ->
    case binary:split(dgiot_mqtt:get_topic(Msg), <<$/>>, [global, trim]) of
        [<<"thing">>, _ProductId, _DevAddr] ->
            [#{<<"thingdata">> := ThingData} | _] = jsx:decode(dgiot_mqtt:get_payload(Msg), [{labels, binary}, return_maps]),
            case ThingData of
                #{<<"command">> := <<"r">>,
                    <<"data">> := Value,
                    <<"di">> := Di,
                    <<"pn">> := SlaveId,
                    <<"product">> := ProductId,
                    <<"protocol">> := <<"modbus">>
                } ->
                    Datas = modbus_rtu:to_frame(#{
                        <<"addr">> => SlaveId,
                        <<"value">> => Value,
                        <<"productid">> => ProductId,
                        <<"di">> => Di}),
                    lists:map(fun(X) ->
                        dgiot_bridge:send_log(ChannelId, "to_device: ~p ", [dgiot_utils:binary_to_hex(X)]),
                        dgiot_tcp_server:send(TCPState, X)
                              end, Datas),
                    {noreply, TCPState#tcp{state = State#state{env = #{product => ProductId, pn => SlaveId, di => Di}}}};
                _ ->
                    {noreply, TCPState}
            end;
        _Other ->
            {noreply, TCPState}
    end;

%% {stop, TCPState} | {stop, Reason} | {ok, TCPState} | ok | stop
handle_info(_Info, TCPState) ->
    ?LOG(info, "TCPState ~p", [TCPState]),
    {noreply, TCPState}.

handle_call(_Msg, _From, TCPState) ->
    {reply, ok, TCPState}.

handle_cast(_Msg, TCPState) ->
    {noreply, TCPState}.

terminate(_Reason, _TCPState) ->
    ok.

code_change(_OldVsn, TCPState, _Extra) ->
    {ok, TCPState}.

get_deviceid(ProdcutId, DevAddr) ->
    #{<<"objectId">> := DeviceId} =
        dgiot_parse:get_objectid(<<"Device">>, #{<<"product">> => ProdcutId, <<"devaddr">> => DevAddr}),
    DeviceId.

create_device(DeviceId, ProductId, DTUMAC, DTUIP) ->
    case dgiot_parse:get_object(<<"Product">>, ProductId) of
        {ok, #{<<"ACL">> := Acl, <<"devType">> := DevType}} ->
            case dgiot_parse:get_object(<<"Device">>, DeviceId) of
                {ok, #{<<"devaddr">> := _GWAddr}} ->
                    dgiot_parse:update_object(<<"Device">>, DeviceId, #{<<"ip">> => DTUIP, <<"status">> => <<"ONLINE">>}),
                    dgiot_task:save_pnque(ProductId, DTUMAC, ProductId, DTUMAC),
                    create_instruct(Acl, ProductId, DeviceId),
                    {DeviceId, DTUMAC};
                _ ->
                    dgiot_device:create_device(#{
                        <<"devaddr">> => DTUMAC,
                        <<"name">> => <<"USRDTU", DTUMAC/binary>>,
                        <<"ip">> => DTUIP,
                        <<"isEnable">> => true,
                        <<"product">> => ProductId,
                        <<"ACL">> => Acl,
                        <<"status">> => <<"ONLINE">>,
                        <<"location">> => #{<<"__type">> => <<"GeoPoint">>, <<"longitude">> => 120.161324, <<"latitude">> => 30.262441},
                        <<"brand">> => <<"USRDTU">>,
                        <<"devModel">> => DevType
                    }),
                    dgiot_task:save_pnque(ProductId, DTUMAC, ProductId, DTUMAC),
                    create_instruct(Acl, ProductId, DeviceId),
                    {DeviceId, DTUMAC}
            end;
        Error2 ->
            ?LOG(info, "Error2 ~p ", [Error2]),
            {<<>>, <<>>}
    end.

create_instruct(ACL, DtuProductId, DtuDevId) ->
    case dgiot_device:lookup_prod(DtuProductId) of
        {ok, #{<<"thing">> := #{<<"properties">> := Properties}}} ->
            lists:map(fun(Y) ->
                case Y of
                    #{<<"dataForm">> := #{<<"slaveid">> := 256}} ->   %%不做指令
                        pass;
                    #{<<"dataForm">> := #{<<"slaveid">> := SlaveId}} ->
                        Pn = dgiot_utils:to_binary(SlaveId),
%%                        ?LOG(info,"DtuProductId ~p DtuDevId ~p Pn ~p ACL ~p", [DtuProductId, DtuDevId, Pn, ACL]),
%%                        ?LOG(info,"Y ~p", [Y]),
                        dgiot_instruct:create(DtuProductId, DtuDevId, Pn, ACL, <<"all">>, #{<<"properties">> => [Y]});
                    _ -> pass
                end
                      end, Properties);
        _ -> pass
    end.
