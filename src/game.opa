/*************************************************************************
 *	Mahjong: An html5 mahjong game built with opa. 
 *  Copyright (C) 2012
 *  Author: winbomb
 *  Email:  li.wenbo@whu.edu.cn
 *
 *  This program is free software: you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation, either version 3 of the License, or
 *  (at your option) any later version.
 *
 *  This program is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *  GNU General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License
 *  along with this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 ************************************************************************/
package mahjong
import-plugin engine2d

type Action.t = {no_act}    //不进行动作  
			 or {peng}      //碰
			 or {gang}      //杠
			 or {gang_self} //自己杠 
			 or {hoo}       //胡
			 or {Card.t discard}   //弃牌
			 or {set_ready} //准备好
			 or {set_ok}	//关闭结算界面
			 or {quit}      //离开游戏
			 or {none}      //尚未选择 

type Game.t = {
	string id,              			//游戏id
	Status.t status,        			//游戏状态
	int curr_turn,           			//当前玩家的位置
	int ready_flags,					//用于表示玩家是否准备好（1 + 2 + 4 + 8）
	int ok_flags, 						//用户表示玩家是否关闭了结算界面
	int last_act,                       //最后一次出手时间，用于判断超时
	int round,							//第几局
	int dealer,							//庄家
	bool change_flag,                   //标志这个游戏自上次广播之后状态（游戏人数，准备状态等）是否变化
	list(int) winners,	 		        //游戏胜利玩家
	option(Card.t) curr_card,   		//当前牌面上打出的牌
	llarray(option(Player.t)) players, 	//游戏玩家
	llarray(option(ThreadContext.client)) clients, 
	llarray(Action.t) actions,          //玩家回合内的动作 
	Board.t board,           			//牌面的情况
	Network.network(Game_msg.t) game_channel,
	Network.network(Chat_msg.t) chat_channel
}

/**
* 游戏信息的定义
* 即在游戏大厅显示游戏列表时的信息
*/
type Game.info = {
	string id,          //游戏Id
	bool in_progress,   //游戏是否在进行中
	int player_cnt,     //玩家个数
	int ready_cnt,      //准备好的个数
}

type Game.ctx = {
    string game_id,   							//游戏名称
	Player.t player,      						//玩家名称
    Network.network(Game_msg.t) game_channel, 	//游戏通道
	Network.network(Chat_msg.t) chat_channel    //聊天通道 
};

set_cookie = %%engine2d.set_cookie%%
get_cookie = %%engine2d.get_cookie%%

DEFAULT_COINS = 1000; //默认的金币数量
ALL_IS_READY = 15; //表示所有玩家都准备好了（1+2+4+8)
ALL_IS_OK = 15;
FLAGS = [8,4,2,1];

public server gmMap = ServerReference.create(stringmap(Game.t) StringMap_empty);

/** 测试第idx个玩家的某个flag是否为真 */ 
public function test_flag(int flags,int idx){
	if(flags <= 0 || flags >= 16) {false} else{
		flag = List.foldi(function(i,f,flags){
			if(flags >= f && i != 3-idx){
				flags - f
			}else flags
		},FLAGS,flags);
		flag != 0
	}
}

/** 设置第idx个玩家的标志 */
public function set_flag(int flags,int idx){
	if(test_flag(flags,idx) || idx <= -1 || idx >= 4) flags else {
		flags + Option.get(List.get(3-idx,FLAGS));
	}
}

public function clear_flag(int flags,int idx){
	if(not(test_flag(flags,idx)) || idx <= -1 || idx >= 4) flags else {
		flags - Option.get(List.get(3-idx,FLAGS));
	}
}

/** */
public function get_flag_cnt(flags){
	result = List.fold(function(f,r){
		if(r.flags >= f) {r with flags: r.flags - f , cnt: r.cnt + 1} else r
	},FLAGS,{~flags,cnt:0});
	result.cnt;
}

module Game {
	AUTO_READY = {false};
	AUTO_RESTART = {false};

	init_board = {
		//初始化创建10个房间
		ignore(for(0,function(i){
			id = "game_{i}"
			game = {
				id:              id, 
				status:			 {prepare},
				winners:         [],
				curr_turn:       0,
				last_act:        0,
				ready_flags: 	 0,
				ok_flags:		 0,
				round:			 1,
				dealer:			 1,
				change_flag:     {false},
				curr_card:       {none},
				players:         LowLevelArray.create(4,{none}),
				clients:         LowLevelArray.create(4,{none}),
				actions:         LowLevelArray.create(4,{none}),
				board:           Board.create(),
				game_channel:    GameNetwork.memo(id),
				chat_channel:    ChatNetwork.memo(id)
			};
			
			ServerReference.update(gmMap,function(map){
				StringMap_add(game.id,game,map)
			});

			i+1
		}, _ <= 9))

		//启动超时检查线程
		Scheduler.timer(2000,function(){
			timestamp = Date.in_milliseconds(Date.now());
			Map.iter(function(_,game){
				if(game.last_act != 0 && timestamp - game.last_act >= 12000){
					match(game.status){
						case {select_action}: Mahjong.default_action(game);
						case {wait_for_resp}: Mahjong.do_action(game);
						default: void 
					}
				}
			},ServerReference.get(gmMap));
		});	

		//每隔2秒向大厅广播本次的游戏玩家变动
		Scheduler.timer(2000,function(){
			result = Map.fold(function(_,game,result){
				if(game.change_flag){
					game_info = {id:game.id,
						rc: get_flag_cnt(game.ready_flags),
						tc: get_player_cnt(game.players),
						st: game.status != {prepare} && game.status != {game_over}
					}
					{msg: game_info} +> result
				}else{ {unchanged} +> result}
			},ServerReference.get(gmMap),[]);

			//清除所有change_flag标志
			ServerReference.update(gmMap,function(map){
				Map.map(function(g){
					{g with change_flag: {false}}
				},map);
			});
			
			//只要有变化，就发送广播消息到大厅
			b_changed = List.fold(function(r,b){
				if(b) b else {
					match(r){
						case {unchanged}: {false}
						case {msg:_}: {true}
					}
				}
			},result,{false});
			if(b_changed) Network.broadcast(result,hall);
		});
	}

	/** 
	* 根据游戏的id获得游戏 
	*/
	function get(game_id){
		Map.get(game_id,ServerReference.get(gmMap));
	}

	function with_game(game_id,(Game.t -> void) f){
		match(get(game_id)){
			case {none}:  void
			case ~{some}: f(some)
		}
	}
	
	/** 获得可以加入的游戏的id（未开始，人数少于4） */
	exposed function get_free_gameid(){
		game_opt = Map.find(function(_,game){
			if(game.status != {prepare} && game.status != {game_over}) {false} else {
				if(get_player_cnt(game.players) >= 4) {false} else {true}	
			}
		},ServerReference.get(gmMap));

		match(game_opt){
			case {none}:  {none}
			case {some:s}: some(s.val.id)
		}
	}
	
	// 向游戏中添加机器人
	function add_bots(game){
		players = LowLevelArray.mapi(game.players)(function(i,player){
			match(player){
				case {none}:{
					name = "Bot {Random.int(2000)}";
					some({~name,idx:i,is_bot:{true},status:{online},coins:DEFAULT_COINS});
				}
				case {some:player}: some(player);
			}
		})

		ready_flags = LowLevelArray.foldi(function(i,player,result){
			match(player){
				case {none} : set_flag(result,i);
				case ~{some}: if(some.is_bot) set_flag(result,i) else result;
			}
		},players,0);

		{game with ~players,~ready_flags}
	}
	
	/** 获得可以加入的游戏的id（未开始，人数为0） */
	exposed function get_empty_gameid(){
		game_opt = Map.find(function(_,game){
			if(game.status != {prepare} && game.status != {game_over}) {false} else {
				if(get_player_cnt(game.players) >= 1) {false} else {true}	
			}
		},ServerReference.get(gmMap));

		match(game_opt){
			case {none}:  {none}
			case {some:s}: some(s.val.id)
		}
	}
	
	/** 获取游戏信息列表 */
	public exposed function get_game_list(){
		Map.fold(function(_,game,result){
			game_info = {id:game.id,
				rc: get_flag_cnt(game.ready_flags),
				tc: get_player_cnt(game.players),
				st: game.status != {prepare} && game.status != {game_over}
			}
			game_info +> result
		},ServerReference.get(gmMap),[]);
	}

	public server function get_player_cnt(players){
		LowLevelArray.fold(function(player,count){
			if(player != {none}) count + 1 else count
		},players,0)
	}

	server function get_online_cnt(players){
		LowLevelArray.fold(function(player,count){
			match(player){
				case {none}: count;
				case ~{some}: if(some.is_bot == {false} && some.status == {online}) count+1 else count
			}
		},players,0);
	}

	public server function game_info(game){
		{id: game.id,
		 in_progress: game.status != {prepare} && game.status != {game_over},
		 player_cnt:  get_player_cnt(game.players),
		 ready_cnt:   get_flag_cnt(game.ready_flags) }

	}
	
	function trans_pile_info(pile_info){
		LowLevelArray.init(4)(function(i){
			pile = LowLevelArray.get(pile_info,i);
			LowLevelArray.fold(function(count,result){
				match(count){
					case 2:  result ^ "2"
					case 1:  result ^ "1"
					default: result ^ "0"
				}
			},pile,"");
		});
	}

	function in_process(game){
		(game.status == {draw_card} || game.status == {select_action} || game.status == {wait_for_resp});
	}
	
	/**
	* 这个方法用于返回一个用于传递消息的Game.msg对象，为了保证在传输过程中
	* 的数据量最小，尝试使用一些缩略。
	*/
	function game_msg(game){
		{id:  	game.id,
		 st: 	encode_status(game.status),
		 ct: 	game.curr_turn,
		 rd:	game.round,
		 dl:	game.dealer,
		 cc:    game.curr_card,
		 rf: 	game.ready_flags,
		 pls: 	game.players,
		 dks:	Board.get_decks(game.board,{true}),
		 dcs: 	game.board.discards,
		 pf:    trans_pile_info(game.board.pile_info)
		}
	}

	function game_obj(game,player){
		{	id: 			game.id,
			status: 		game.status,
			curr_turn: 		game.curr_turn,
			round:			game.round,
			dealer:			game.dealer,
			curr_card: 		game.curr_card,
			ready_flags:    game.ready_flags,
			players: 		game.players,
			decks: 			Board.get_decks(game.board,{false}),
			discards: 		game.board.discards,
			pile_info: 		trans_pile_info(game.board.pile_info),
			player: 		player,
			idx: 			player.idx,
			deck: 			Game.get_player_deck(game.id,player),
			is_ting: 		{false},
			is_ok:			{false}
		}
	}

	/**
	* 更新服务器端游戏
	*/
	function update(game){
		ServerReference.update(gmMap,function(map){
			Map.replace_or_add(game.id,function(_){
				{game with last_act: Date.in_milliseconds(Date.now())}
			},map);
		});
		Option.get(Map.get(game.id,ServerReference.get(gmMap)));
	}

	/** 更新玩家 */
	exposed function update_player(game,player){
		match(get(game.id)){
			case {none}: game;
			case {some:g}: {
				players = LowLevelArray.mapi(g.players)(function(i,p){
					match(p){
						case {none}: {none}
						case {some:p}:{
							if(p.name == player.name && player.idx == i) some(player) else some(p)
						}
					}
				});
				{g with ~players} |> update(_);
			}
		}
	}
	
	// 获得鼠标点击事件在画布上的坐标 
	client function get_pos(event){
		canvas_pos = Dom.get_position(#container);
		mouse_pos = event.mouse_position_on_page;
		s = Render.g_scale.get();
		x = Float.to_int(Float.of_int(mouse_pos.x_px - canvas_pos.x_px) / s);
		y = Float.to_int(Float.of_int(mouse_pos.y_px - canvas_pos.y_px) / s);
		if(Render.g_rotate.get()){
			x = x + 300; y = y + 400;
			{x:y, y: Render.SRN_HEIGHT - x}
		}else{
			x = x + 400; y = y + 300;
			~{x,y}
		}
	}

	/**
	* 处理鼠标点击的事件 
	*/
	client function mouse_down(event){
		pos = get_pos(event);
		if(Button.is_pressed(pos,Render.btn_exit)){
			//退出游戏
			Client.goto("/hall");
		}else{
			game = get_game();
			if(game.status == {prepare} || game.status == {wait_for_resp} 
				|| game.status == {show_result} || game.curr_turn == game.idx){
				action = Mahjong.get_action(pos,game);
				match(action){
					case {none}: void
					default: {
						Render.refresh();
						Mahjong.request_action(game.id,game.idx,action);
					}
				}
			}
		}
	}

	/**
	* 收到游戏消息后的处理函数
	* @msg Game_msg.t 游戏消息 
	*/
	client function game_msg_received(msg){
		match(msg){
			case {GAME_REFRESH: game_msg}:{
				Render.update(game_msg);
				Render.update_deck();
				Render.refresh();
			}
			case {GAME_START: game_msg}:{
				play_sound("start.wav");
				Render.update(game_msg);
				Render.update_deck();
				Render.start_timer();
				Render.refresh();

				action_flag = Render.get_action_flag();
				if(action_flag >= 2) Render.show_menu(action_flag);
			}
			case {GAME_RESTART: game_msg}:{
				Render.update(game_msg);
				Render.refresh();
			}
			case {PLAYER_CHANGE: game_msg}:{
				Render.update(game_msg);
				Render.refresh();
			}
			case {DISCARD_CARD: msg}:{  //玩家弃牌消息
				play_sound("da.wav");
				Render.stop_timer()
				Render.recv_discard_msg(msg);
				Render.refresh();
				
				//如果可以碰/杠/胡，则显示菜单
				resp_flag = Render.get_resp_flag();
				if(resp_flag >= 2) Render.show_menu(resp_flag); 
			}
			case {NEXT_TURN: game_msg}:{
				Render.update(game_msg);
				if(game_msg.ct == get_game().idx) Render.update_deck();
				Render.start_timer();
				Render.refresh();
				
				action_flag = Render.get_action_flag();
				if(action_flag >= 2) Render.show_menu(action_flag);
			}
			case {NEXT_ACTION: game_msg, ACT: act}:{
				Render.update(game_msg);
				if(game_msg.ct == get_game().idx) Render.update_deck();
				Render.start_timer();
				Render.refresh();
				
				action_flag = Render.get_action_flag();
				if(action_flag >= 2) Render.show_menu(action_flag);
				
				play_sound("pung.wav");
				rel_pos = Board.get_rel_pos(get_game().idx,game_msg.ct);
				Render.draw_act(rel_pos,act);
			}
			case {HOO:winners}: {
				set_game({get_game() with status: {game_over},is_ok:{false},is_ting:{false}});
				Render.stop_timer();
				Render.refresh();
				player_idx = get_game().idx;
				List.iter(function(win_idx){
					if(player_idx == win_idx) play_sound("win.wav")
					Render.draw_win(Board.get_rel_pos(player_idx,win_idx))
				},winners);				
			}	
			case {SHOW_RESULT: result}: {
				game = {get_game() with status:{show_result}, is_ok: {false}}
				match(result){
					case {none}: {
						set_game(game);
						Render.refresh();
						Render.show_draw_play(game,225,75);
					}
					case ~{some}: {
						players = Mahjong.update_scores(game.players,some);
						set_game({game with ~players}); 
						
						play_sound("countfan.wav");
						Render.refresh();
						Render.show_result(game,some,225,75);
					}
				}
			}
			case {OFFLINE: player}: {
				game = get_game();
				players = LowLevelArray.mapi(game.players)(function(i,p){
					match(p){
						case {none}: {none}
						case {some:p}: {
							if(p.name == player.name && player.idx == i){
								some({p with status: {offline}});
							}else some(p)
						}
					}
				});
				set_game({game with ~players});
				Render.refresh();
			}
			case {PLAYER_READY: ready_flags}:{
				game = {get_game() with ~ready_flags};
				set_game(game);
				if(game.status == {prepare} || (game.status == {show_result} && game.is_ok)){
					Render.refresh();
				}
			}
			default: jlog("msg: {msg}");
		}
	}

	//收到聊天消息
	client function user_update(msg){
		line = <li><div class="author">{msg.author}: </div>{msg.text} </li>
		#chat_messages =+ line
		Dom.scroll_to_bottom(#chat_messages)
	}
	
	/**
	* 获得空的座位 
	*/
	function get_free_place_idx(game){
		LowLevelArray.foldi(function(i,player,n){
			if(n != -1) n else {
				if(player == {none}) i else n
			}
		},game.players,-1);
	}

	/**
	* 为player安排座位
	* 返回：{none} or {some:int}
	*/
	function assign_place(game,player){
		clnt = match(ThreadContext.get({current}).key){
			case {`client`:c}: c.client
			default: ""
		}

		//先找其ctx.client与clnt一样（说明是同一个客户端的）的玩家，再找空位。
		//否则返回{none},表示没有位置可以分配。
		LowLevelArray.foldi(function(i,p,result){
			match(result){
			case {some:idx}: {
				match(p){
				case {none}: {some:idx}
				case {some:p}:{
					match(LowLevelArray.get(game.clients,i)){
					case {none}: {some:idx}
					case {some:ctx}:{
						if(p.name == player.name && ctx.client == clnt) {some:i} else {some:idx}
					}}
				}}
			}
			case {none}: {
				match(p){
				case {none}: {some:i}
				case {some:p}:{
					match(LowLevelArray.get(game.clients,i)){
					case {none}: {some:i}
					case {some:ctx}:{
						if(p.name == player.name && ctx.client == clnt) {some:i} else {none}
					}}
				}}
			}}
		},game.players,{none});		
	}

	client function load_page(game,idx){
		lang = I18n.lang();
		if(String.has_prefix(lang,"zh") || String.has_prefix(lang,"jp")
		   || String.has_prefix(lang,"tw") || String.has_prefix(lang,"hk")){
				Render.g_zh.set({true})
		}else Render.g_zh.set({false})

		//加载资源
		imgs = ["actions.png","table_bg.png","board.png","result.png","arrow.png","win.png","en_menu_bar.png","cn_menu_bar.png",
				"ting.png","dialog.png","tiles.png","tiles_small.png","numbers.png","start.png","offline.png","player_frame_h.png",
				"player_frame_v.png","portrait.jpg","eswn.png","btn_tutor.png","exit.png","setting.png"];
		auds = ["start.wav","da.wav","pung.wav","countfan.wav","win.wav"];

		player = Option.get(LowLevelArray.get(game.players,idx));
		preload(imgs,auds,function(){
			Dom.set_value(#loading_info,"prepare game...");
			game_obs = Network.observe(game_msg_received,game.game_channel);
			chat_obs = Network.observe(user_update,game.chat_channel);
			
			ck_player = get_cookie("player");
			ck_coins = get_cookie("coins");
			coins = if(ck_player != player.name || String.is_empty(ck_coins)) DEFAULT_COINS else string_to_int(ck_coins);
			player = {player with coins: coins};

			game = update_player(game,player);
			set_game(game_obj(game,player));
			
			//离开页面的提示（对Opera无效）
			Dom.bind_beforeunload_confirmation(function(_){
				{some: "Are you sure to quit?"}
			});
			Dom.bind_unload_confirmation(function(_){
				Mahjong.quit(game.id,player.idx);
				Network.unobserve(game_obs);
				Network.unobserve(chat_obs);
				{none}
			});
				
			//广播游戏信息
			Network.broadcast({PLAYER_CHANGE: game_msg(game)},game.game_channel);
			
			if(Render.g_zh.get()) Render.g_show_classic_tile.set({true});

			//去掉#gamecanvas的loading样式
			Render.adjust();
			Render.refresh();
			Dom.remove(#gmloader);		
		});
		
		if(AUTO_READY || player.is_bot) Mahjong.set_ready(game,player.idx);
	}

	function game_ready(game,idx){
		load_page(game,idx);

		_ = ClientEvent.set_on_disconnect_client(function(ctx){
			//如果ctx和game的第idx个client一致，说明这个玩家处于死链接状态，去除之。
			with_game(game.id,function(game){
				match(LowLevelArray.get(game.clients,idx)){
					case {none}: void
					case {some:c}:{
						if(c.client == ctx.client && c.page == ctx.page){
							Mahjong.quit(game.id,idx);
						}
					}
				}
			});
		});

		void;
	}
	
	/** 
	* 游戏视图
	*/
	function game_view(game,idx){
		player = Option.get(LowLevelArray.get(game.players,idx));
		Resource.full_page("Mahjong",
			<>
			<div class="game" onready={function(_){game_ready(game,idx)}}>
			  <div id=#container>
			  	<div id=#gmloader >
					<p id=#loading_info>loading</p>
				</div>
			  	<canvas id=#gmcanvas width="800" height="600" 
					onmousedown={function(event){mouse_down(event)}}>
					"Your browser does not support html5 canvas element."
				</canvas>
			  </div>
			  <div id="chat">
			  	<div id="chat_title">Chat</div>
				<div id="chat_box">
					<ul id=#chat_messages></ul>
					<input id=#entry type="text" class="chat_textbox" 
					onnewline={function(_){post_chat_msg(player.name,game.chat_channel)}}></input>
				</div>
			  </div>
			</div>		
			</>,
			<>
			<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
			<link rel="stylesheet" type="text/css" href="/resources/css/game.css" media="only screen and (min-width:800px)">
			<link rel="stylesheet" type="text/css" href="/resources/css/game_small.css"
				  media="only screen and (min-width:240px) and (max-width:800px)">
			</>,
			{success},[]
		); 
	}

	@async function post_chat_msg(author,channel){
		text = Dom.get_value(#entry);
		if(not(String.is_empty(text))){
			Dom.clear_value(#entry)
			Network.broadcast(~{author,text},channel)
		}
	}

	/** 开始游戏 */
	function start(game){
		idx = mod(game.dealer / 10000,4);
		game = {game with 
			board: 			Board.prepare(game.board,idx),
			status: 		{select_action},
			curr_turn: 		idx,
			change_flag: 	{true},
			ready_flags: 	0,
			ok_flags:		0,
		}		
		Mahjong.reset_actions(game);
	}
	
	/** 重新开始游戏 
	* ready: 是否需要玩家重现点ready
	*/
	function restart(game){
		curr_turn = mod(game.dealer / 10000,4);
		game = {game with board: Board.create()}
		game = match(AUTO_RESTART){
			case {false}: {{game with board: Board.create()} with status: {prepare}}
			case {true}:  {{game with board: Board.prepare(Board.create(),curr_turn)} with status: {select_action}}
		}
		
		//去除掉状态为offline的玩家，更新所有玩家的准备状态为{false}
		players = LowLevelArray.mapi(game.players)(function(_,p){
			match(p){
			case {none}:   {none}
			case {some:p}: if(p.status == {offline}) {none} else some(p)
			}
		});
		
		//把所有机器人的Ready状态设置为ready
		ready_flags = LowLevelArray.foldi(function(i,player,result){
			match(player){
				case {none} : result 
				case ~{some}: if(some.is_bot) set_flag(result,i) else result;
			}
		},players,0);

		is_winner = List.exists(function(idx){idx == game.dealer / 10000},game.winners); 
		dealer = if(is_winner) game.dealer + 1 else mod((game.dealer / 10000) + 1,4)*10000 + 1
		round  = if(dealer == 1) game.round + 1 else game.round

		{game with ~players, ~ready_flags, ~round, ~dealer, ~curr_turn,
		 ok_flags:0, change_flag:{true}} |> Mahjong.reset_actions(_);
	}

	function reset(game){
		{game with 
			status:			 {prepare},
			winners:         [],
			curr_turn:       0,
			last_act:        0,
			ready_flags: 	 0,
			ok_flags:		 0,
			round:			 1,
			dealer:			 1,
			change_flag:     {false},
			curr_card:       {none},
			players:         LowLevelArray.create(4,{none}),
			clients:         LowLevelArray.create(4,{none}),
			actions:         LowLevelArray.create(4,{none}),
			board:           Board.create()
		}		
	}

	/** 获取某个玩家的deck */
	exposed function get_player_deck(game_id,player){
		match(get(game_id)){
			case {none}: Card.EMPTY_DECK
			case {some:game}: Board.get_player_deck(game.board,player);
		}
	}
}
