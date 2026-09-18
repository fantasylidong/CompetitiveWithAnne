// Coordinates use 1 display unit = 100 Hammer units. These are reproducible
// explanatory tracks, not recorded game telemetry or an implementation of NextBot.
export const HOP_TIME = 0.773;
const DROP_LAUNCH = HOP_TIME * 2;
const DROP_SPEED = 8 / DROP_LAUNCH;
const DROP_VZ = 7.5 * HOP_TIME / 2;
const DROP_AIR_TIME = (DROP_VZ + Math.sqrt(DROP_VZ ** 2 + 2 * 7.5 * 2)) / 7.5;
const DROP_LAND = DROP_LAUNCH + DROP_AIR_TIME;
const DROP_LAND_X = -1 + DROP_SPEED * DROP_AIR_TIME;
const DROP_FINISH = DROP_LAND + (8.8 - DROP_LAND_X) / DROP_SPEED;
export const DIFFICULTIES = [
  { angle:8, minTurn:60, legacyMinTurn:60, impulse:.40, first:0, cap:5, stop:2.2 },
  { angle:10, minTurn:55, legacyMinTurn:55, impulse:.48, first:.2, cap:6, stop:1.9 },
  { angle:12, minTurn:50, legacyMinTurn:50, impulse:.55, first:.4, cap:7, stop:1.6 },
  { angle:15, minTurn:45, legacyMinTurn:45, impulse:.60, first:.6, cap:8, stop:1.35 },
  { angle:18, minTurn:45, legacyMinTurn:45, impulse:.65, first:.8, cap:8, stop:1.2 },
  { angle:20, minTurn:45, legacyMinTurn:45, impulse:.65, first:1, cap:10, stop:1.2 },
];
const frame = (t,x,y,z,mode='run') => ({t,p:[x,y,z],mode});
const track = rows => rows.map(row => frame(...row));
const box = (x,y,z,w,h,d,kind='wall') => ({x,y,z,w,h,d,kind});
const person = (name, rows) => ({name,track:track(rows)});
const moment = (t,label,old,current,refactor=current) => ({t,label,old,current,refactor});
const shared = {
  duration:8, floor:[26,14], center:[0,0,0], route:[], geometry:[], ladders:[],description:'同一地形与目标，观察两个版本的行动选择和状态转换。',
  conditions:'画面只展示一组可复现的情景。实际结果还受路径快照、可见性、地图 nav、碰撞检测和插件配置影响。',
};
export const SCENARIOS = [
  {
    ...shared,id:'far',group:'移动与转向',title:'远距离左右连跳',tag:'2.1 新增',
    description:'开阔、同层、可视的直路：看每次落地后是否换边，以及接近目标后何时收回侧跳。',
    dynamic:true,floor:[34,14],center:[2,0,0],route:[[-9,0,0],[13,0,0]],
    survivors:[person('S1',[[0,10,0,0],[4,13,0,0],[8,13,0,0]])],
    old:'没有主动左右交替的逻辑。起跳通常朝目标预测位置推进；原生单独左右按键可能加侧推，所以并非绝对只能走直线。',
    current:'2.1 在目标超过 600 hu、同层可视且路径支持直追时，逐跳左右交替。空中维持本跳方向；接近目标、侧路受阻或即将经过特殊路径段时取消偏角。',
    refactor:'2.0 已按路径决定连跳方向，但还没有主动左右交替。本场景的安全直路通常仍呈近直线；左右连跳是 2.1 新增。',
    source:'movement.inc · Movement_GroundHop / Movement_UpdateAirDirection；动态配置 ai_tank3_bhop_strafe_angle、ai_tank3_bhop_strafe_min_dist。',
    moments:[moment(0,'远距起跳','朝预测点起跳','允许安全侧跳','沿直路起跳'),moment(.78,'落地换边','继续直追','确认落地后换边','仍无主动侧跳'),moment(2.32,'连续观察','近直线连跳','左右交替；按原门槛修正','保持路径连跳'),moment(5.4,'接近目标','接近后停跳出拳','距离不足 600 hu 时取消偏角','接近后停跳出拳')],
  },
  {
    ...shared,id:'moving',group:'移动与转向',title:'追逐横移的目标',tag:'追人门槛已恢复',
    description:'生还者持续横移：直追角度门槛已恢复原值，小幅走位通常等到下一跳重新对准；可观察左右连跳的差异。',
    dynamic:true,floor:[34,16],center:[2,0,1],route:[[-9,0,0],[8,0,0],[13,0,4]],
    survivors:[person('S1',[[0,10,0,0],[2,12,0,1.6],[4,14,0,3.2],[6,14,0,.5],[8,14,0,-1.8]])],
    old:'地面起跳会预测目标位置，但空中方向误差要进入较大的角度窗口才修正。小幅横移容易表现为一跳内基本不转，落地后重新对准。',
    current:'2.1 保留每 0.05 秒刷新与转向安全检查；追人门槛恢复为 60/55/50/45/45/45°，小角差不再主动追随。上限配置恢复 135°，实际仍受共享代码 89° 限制；沿导航路径跟随仍从 1° 开始。',
    refactor:'2.0 改善了路径选择，空中追人使用较大的角度窗口；当前 2.1 也已恢复相同追人门槛，保留路径续接与左右连跳。',
    source:'movement.inc · Movement_AirControl / Movement_UpdateAirDirection；ai_tank3_airvec_modify_degree / interval。',
    moments:[moment(0,'开始追逐','预测起跳方向','预测起跳并检查侧路'),moment(1.7,'目标横移','小角度变化不立即跟随','小角差保持本跳方向','等待较大角差或下一跳'),moment(4.1,'目标折返','下一跳重新定向','达到角度门槛或下一跳再调整','逐跳重定向'),moment(6.3,'近身跟随','转为近身追逐','取消侧跳，继续追人')],
  },
  {
    ...shared,id:'corner',group:'移动与转向',title:'绕过弯道与墙角',tag:'2.0 + 2.1',
    description:'目标在墙后，路径绕过墙角。绿色轨迹会续接下一个可达前瞻点。',
    geometry:[box(1,1.4,-2,6,2.8,3.5)],route:[[-9,0,-3],[-4,0,-3],[-3.8,0,1],[-2,0,1],[6,0,1],[8,0,-3]],
    survivors:[person('S1',[[0,8,0,-3],[8,8,0,-3]])],
    oldTrack:track([[0,-9,0,-3,'hop'],[1.3,-4,0,-3,'hop'],[2,-2.9,0,-2.8,'wait'],[3,-3.3,0,-1,'run'],[4.2,-3.8,0,1,'hop'],[6.5,5,0,1,'run'],[8,7,0,-1]]),
    newTrack:track([[0,-9,0,-3,'hop'],[1.2,-4.7,0,-3,'hop'],[1.7,-4,0,-1.8,'hop'],[2.25,-3.6,0,.7,'hop'],[2.8,-1.7,0,1,'hop'],[5,6,0,1,'run'],[6.4,7.5,0,-2.4,'wait'],[8,7.5,0,-2.4]]),
    refactorTrack:track([[0,-9,0,-3,'hop'],[1.3,-4.4,0,-3,'hop'],[2.1,-3.8,0,1,'wait'],[2.4,-3.8,0,1,'hop'],[5.4,6,0,1,'run'],[7,7.5,0,-2.4,'wait'],[8,7.5,0,-2.4]]),
    old:'旧路径连跳主要用于无视野且较远的情况；路径跳起后仍盯着起跳时的前瞻点，越过节点后不及时续接，可能贴墙或在拐点修正迟滞。',
    current:'2.0 优先判断路径是否支持直追；2.1 再加入空中前瞻刷新，经过节点后可接续安全的下一段，从 1° 开始平滑跟路。锐角仍可能需要落地再转。',
    refactor:'2.0 已沿 NextBot 路径绕墙，避免把可见目标的直线方向直接当路线；空中续接能力弱于 2.1，图中拐点停顿仅作说明。',
    source:'path.inc · Path_GetLookAhead；movement.inc · Movement_GroundHop / Movement_UpdateAirDirection。',
    moments:[moment(0,'走向拐点','使用起跳时前瞻','依据可达路径起跳'),moment(2.1,'经过墙角','旧前瞻可能造成修正迟滞','小角度转向前验证安全','沿路径等待下一跳'),moment(2.5,'续接路径','落地重新找方向','空中续接下一段','重新起跳接下一段'),moment(5.5,'接近目标','绕行追逐','恢复正常直追')],
  },
  {
    ...shared,id:'narrow',group:'移动与转向',title:'窄路与低顶约束',tag:'2.1 安全检查',
    description:'给侧向转弯留一个看似有空隙、实际容不下 Tank 的位置，观察它是否强行侧跳。',
    geometry:[box(0,1.25,-1.5,14,2.5,.35),box(0,1.25,1.5,14,2.5,.35),box(3,1.7,0,3,.24,2.65,'ceiling')],
    route:[[-9,0,0],[9,0,0]],survivors:[person('S1',[[0,9,0,0],[8,9,0,0]])],
    oldTrack:track([[0,-9,0,0,'hop'],[2,-3,0,0,'hop'],[3.3,.5,0,0,'hop'],[3.7,2,0,0,'wait'],[4.6,2,0,0,'run'],[6,5.5,0,0,'hop'],[8,8,0,0]]),
    newTrack:track([[0,-9,0,0,'hop'],[2,-3,0,0,'hop'],[3.3,.5,0,0,'run'],[5.5,5.5,0,0,'hop'],[7,8,0,0,'wait'],[8,8,0,0]]),
    old:'旧版已有部分起跳安全检测，不能说它完全不避障；但空中改向缺少对剩余完整抛物线的再次验证，某些低顶或侧墙组合会造成碰撞和迟滞。',
    current:'2.1 用实际碰撞体分段检查剩余飞行路线，覆盖墙、低顶和断层。侧跳候选不安全时回到正常方向；图中低顶段用地面通行示意对危险连跳的拒绝。',
    refactor:'2.0 已在地面起跳检查完整路线，因此这段低顶可通过停止连跳处理；2.1 进一步覆盖每次空中转向。此静态场景两版表现可能相同。',
    source:'movement.inc · Movement_IsTurnRouteSafe / Movement_GroundHop；ai_helpers 的跳跃路线检测。',
    moments:[moment(0,'进入窄路','尝试直路连跳','侧向受阻，取消蛇形'),moment(3.2,'接近低顶','旧检测可能漏掉后续改向碰撞','拒绝危险飞行路线'),moment(4,'通过低顶','可能碰顶减速','保留安全的正常路线'),moment(6,'离开窄段','恢复追逐','满足条件才恢复连跳')],
  },
  {
    ...shared,id:'ladder',group:'地形与寻路',title:'目标在梯子顶端',tag:'2.0 重构',duration:10,
    geometry:[box(6,1.28,0,7,2.56,6,'platform')],ladders:[{x:2.35,z:0,height:2.56}],route:[[-9,0,0],[1.8,0,0],[2.3,2.56,0],[4,2.56,0]],
    survivors:[person('S1',[[0,4,2.56,0],[10,4,2.56,0]])],
    oldTrack:track([[0,-9,0,0,'hop'],[2.5,1.6,0,0,'wait'],[4.5,1.6,0,0,'retreat'],[6,-1.2,0,0,'wait'],[10,-1.2,0,0]]),
    newTrack:track([[0,-9,0,0,'hop'],[2,-2.3,0,0,'run'],[3.9,1.8,0,0,'climb'],[6.6,2.3,2.56,0,'run'],[7.4,3.3,2.56,0,'punch'],[10,3.3,2.56,0]]),
    old:'按目标预测点直冲可能到墙根；旧梯子近邻判断较粗，头顶卡处理与撤离命令还可能打断上梯。这里展示一次不利分支。',
    current:'从路径中识别真正要经过的梯口，先限速，进入让行范围后停跳并压回跑速；爬梯锁视角、冻结换目标。可达的头顶目标也会获得更长观察时间。',
    source:'path.inc · Path_GetSpecial；movement.inc · Movement_ApplyLadderWindow；overhead.inc · 头顶卡可达性检查。',
    moments:[moment(0,'靠近梯口','朝高处目标推进','按入口距离限制连跳'),moment(2,'梯前减速','可能到墙根停滞','停跳，压回跑速'),moment(4,'开始上梯','旧命令可能干扰爬梯','锁定目标并上梯'),moment(7.4,'登上平台','不利分支：撤离后停顿','近身出拳')],
  },
  {
    ...shared,id:'passby',group:'地形与寻路',title:'路过无关的梯子',tag:'2.0 重构',
    geometry:[box(0,1.5,-3,3,3,1,'platform')],ladders:[{x:-.8,z:-2.45,height:3,face:'z'}],route:[[-9,0,-1],[9,0,-1]],
    survivors:[person('S1',[[0,10,0,-1],[8,10,0,-1]])],
    oldTrack:track([[0,-9,0,-1,'hop'],[1.8,-2.4,0,-1,'run'],[3.4,1.2,0,-1,'hop'],[5.8,8.8,0,-1,'wait'],[8,8.8,0,-1]]),
    newTrack:track([[0,-9,0,-1,'hop'],[4.8,8.8,0,-1,'wait'],[8,8.8,0,-1]]),
    old:'靠近任意梯子实体中心约 180 hu，或当前 nav 区有梯，就可能暂停连跳。即使完全不打算爬这架梯子，也会受到影响。',
    current:'有新鲜路径快照时，优先检查路线中即将经过的梯段；无关梯子不会触发让行。这里用直线路径隔离演示梯子判定，未叠加主动蛇形。',
    conditions:'本场景假定路径快照有效。快照失效时会回退实体梯检测，因此并非任何时候路过梯子都不停跳。',
    source:'movement.inc · Movement_ApplyLadderWindow；path.inc · 路径特殊段选择。',
    moments:[moment(0,'起跳接近','正常连跳','正常连跳'),moment(1.8,'经过梯旁','无关梯子也可能触发停跳','路径不经过梯口，继续跳'),moment(3.4,'离开梯旁','恢复连跳','继续追逐')],
  },
  {
    ...shared,id:'drop',group:'地形与寻路',title:'高台下落接连跳',tag:'2.1 保速衔接',
    description:'已知路径通向下方开阔地面：保留前冲速度跃过边沿，落地立即接下一跳。可切换 2.0 查看此前的提前减速。',
    geometry:[box(-6,1,0,12,2,9,'platform')],route:[[-9,2,0],[-.7,2,0],[.8,0,0],[9,0,0]],
    survivors:[person('S1',[[0,10,0,0],[8,10,0,0]])],
    oldTrack:track([[0,-9,2,0,'hop'],[2.1,-.6,2,0,'fall'],[3.1,4.7,0,0,'hop'],[4.5,8.8,0,0,'wait'],[8,8.8,0,0]]),
    newTrack:track([[0,-9,2,0,'hop'],[DROP_LAUNCH,-1,2,0,'drop-hop'],[DROP_LAND,DROP_LAND_X,0,0,'hop'],[DROP_FINISH,8.8,0,0,'punch'],[8,8.8,0,0]]),
    refactorTrack:track([[0,-9,2,0,'hop'],[1.9,-1.5,2,0,'run'],[2.7,.35,2,0,'fall'],[3.5,1.8,0,0,'hop'],[5.6,8.8,0,0,'wait'],[8,8.8,0,0]]),
    old:'可视直追不完整理解深下落等特殊路径段，自然下落还可能继承上一跳的修正状态，出现额外朝人拧向或补速。',
    current:'2.1 对路径明确、落差不超过 256 hu 的普通下落不再一律提前限速。按实际落差计算更长的腾空时间，检查完整抛物线和落点支撑后保速跃出；下落中保持前冲方向，落地立即获得正常续跳加速度。',
    refactor:'2.0 把超过 56 hu 的下落段都纳入停跳窗口，提前压低起跳速度，再走到边沿自然下落。这个处理偏保守，当前 2.1 已对经过验证的普通落差放开。',
    conditions:'图中为 200 hu 落差且下方地面开阔。无路径、落点无支撑、飞行中撞墙/低顶、前方梯口/跳跃间隙或落差超过 256 hu 时，不强行连跳。空中不会再次起跳；“续跳”发生在着地之后。',
    source:'path.inc · DropDown / Path_GetLookAhead；movement.inc · Movement_IsDropHopSafe；共享落地连跳状态。',
    moments:[moment(0,'接近边沿','连续加速','连跳前进，不因普通落差预先减速','按剩余距离限速'),moment(DROP_LAUNCH,'越沿起跳','朝下方目标推进','检查延长后的飞行路线并保速起跳','靠近边沿，准备停跳'),moment(2.3,'下落中','旧状态可能残留','沿已验证方向惯性下落','停跳，步行到边沿'),moment(DROP_LAND,'落地续跳','继续追逐','落地立即接下一跳','自然下落，等待着地')],
  },
  {
    ...shared,id:'target',group:'目标与战斗',title:'近的目标未必好到达',tag:'2.0 重构',
    geometry:[box(0,.9,-1.8,3.7,1.8,3,'platform')],route:[[-6,0,0],[0,0,2.8],[3,0,3]],
    survivors:[person('A',[[0,-.4,1.8,-1.7],[8,-.4,1.8,-1.7]]),person('B',[[0,3,0,3],[8,3,0,3]])],
    oldTrack:track([[0,-6,0,0,'run'],[2,-2.45,0,-1.5,'wait'],[4,-2.45,0,-1.5,'run'],[5.5,-3.5,0,.5,'run'],[7,-2.45,0,-1.5,'wait'],[8,-2.45,0,-1.5]]),
    newTrack:track([[0,-6,0,0,'hop'],[1.7,-1.5,0,2.5,'hop'],[2.7,2.1,0,3,'punch'],[8,2.1,0,3]]),
    old:'通常接受 target_override 或原生选敌结果；某些情况下偏向直线更近的高处 A。头顶卡时的替代选敌也按直线距离，缺少统一的寻路代价比较。',
    current:'统一选敌器以分档寻路距离排名，保留被控、倒地、安全屋等过滤。切换需要明显收益，并有约 2 秒粘滞；图中选择实际更容易到达的地面 B。',
    conditions:'A、B 的寻路代价为情景设定，不是根据页面几何运行 nav 得到。分档距离是近似值，并非全图精确最短路。',
    source:'target.inc · Target_SelectVictim / Target_Score；L4D2_OnChooseVictim。',
    moments:[moment(0,'比较目标','可能偏向直线更近的 A','比较可达路径代价'),moment(1,'确认追逐','朝高处 A 靠近','选择地面 B'),moment(2.7,'近身接触','墙根停滞或来回换靶','换靶粘滞保持追逐 B')],
  },
  {
    ...shared,id:'alt',group:'目标与战斗',title:'头顶卡住，有其他目标',tag:'2.0 重构',floor:[20,12],
    geometry:[box(3,.9,0,3,1.8,4,'platform')],route:[[.9,0,0],[-6,0,3]],
    survivors:[person('A',[[0,1.9,1.8,0],[8,1.9,1.8,0]]),person('B',[[0,-6,0,3],[8,-6,0,3]])],
    oldTrack:track([[0,.9,0,0,'wait'],[2,.9,0,0,'wait'],[3.2,.9,0,0,'run'],[6,-5.2,0,3,'punch'],[8,-5.2,0,3]]),
    newTrack:track([[0,.9,0,0,'wait'],[2,.9,0,0,'hop'],[4,-5.2,0,3,'punch'],[8,-5.2,0,3]]),
    old:'确认头顶卡后也会屏蔽原目标并找其他人，但通过 CommandABot 强制切换；原生行为和命令状态之间可能发生冲突。图中延迟是示意。',
    current:'确认原地停滞且高处目标不可达后，暂时屏蔽该目标 10 秒，交由统一选敌器选择 B。无需强制追人命令；如果路径能经梯攀爬到达，会延长观察期。',
    source:'overhead.inc · 头顶卡判定与屏蔽；target.inc · 统一替代目标选择。',
    moments:[moment(0,'开始观察','够不到高处 A','观察停滞和可达性'),moment(2,'确认卡位','屏蔽 A 并发强制切换命令','屏蔽 A，统一选敌器改选 B'),moment(4,'追逐替代者','命令状态可能延迟切换','沿可达路线追 B')],
  },
  {
    ...shared,id:'solo',group:'目标与战斗',title:'头顶卡住，只剩一个人',tag:'2.0 重构',duration:10,floor:[16,12],
    geometry:[box(3,.9,0,3,1.8,4,'platform')],route:[[.9,0,0],[-2,0,0]],
    survivors:[person('S1',[[0,1.9,1.8,0],[10,1.9,1.8,0]])],
    oldTrack:track([[0,.9,0,0,'wait'],[2,.9,0,0,'retreat'],[4,-2,0,0,'wait'],[10,-2,0,0]]),
    newTrack:track([[0,.9,0,0,'wait'],[2,.9,0,0,'retreat'],[4,-2,0,0,'throw'],[7,-2,0,0,'run'],[10,.5,0,0]]),
    rock:{start:4.8,end:6.2,old:false,from:[-2,.94,0],to:[1.9,2.2,0],arc:2},
    old:'没有其他合格目标时会尝试撤离投石，但旧 MOVE 命令复位不完整，可能撤到位置后还留在命令状态中，出现罚站。',
    current:'统一投石计划挑选可达撤离点，到位或超时都会 RESET，恢复投石与正常追逐。撤不开且水平距离足够时可原地投；过近则不强行投石。',
    source:'overhead.inc · 撤离投石计划 / RESET / 超时与停滞检查；command.inc。',
    moments:[moment(0,'头顶卡位','原地够不到目标','原地够不到目标'),moment(2,'没有替代者','MOVE 撤离','挑选可达撤离点'),moment(4,'撤到位置','旧 MOVE 可能残留','RESET 后准备投石'),moment(4.8,'投出石头','不利分支：持续罚站','按计划投石'),moment(7,'恢复行动','可能仍停在撤离点','清理计划并恢复追逐')],
  },
  {
    ...shared,id:'rider',group:'目标与战斗',title:'生还者骑在头上',tag:'2.0 重构',floor:[12,9],
    survivors:[person('S1',[[0,0,.94,0],[8,0,.94,0]])],
    oldTrack:track([[0,0,0,0,'punch'],[3,0,0,0,'retreat'],[4.6,-2.6,0,0,'wait'],[8,-2.6,0,0]]),
    newTrack:track([[0,0,0,0,'punch'],[3,0,0,0,'throw'],[5,0,0,0,'wait'],[8,0,0,0]]),
    rock:{start:3.8,end:4.5,old:false,from:[0,.94,0],to:[0,1.6,0],arc:.6},
    old:'两版都会识别骑头并尝试向上挥拳；旧版在持续打不到约 3 秒后转入撤离投石，可能把动作打断，并留有命令残留风险。',
    current:'保留正常挥拳和额外向上扫拳。持续 3 秒打不到时，直接原地对骑手投石，不先后撤；水平距离接近零时也有瞄准兜底。',
    conditions:'此处演示持续打不到的分支；若上挥拳能够命中，就继续出拳，不必等到投石。蓝色角色跟随 Tank 移动以表示持续骑头。',
    source:'overhead.inc · 骑头检测 / 原地投石；combat.inc · 向上 SweepFist / 零水平距离兜底。',
    moments:[moment(0,'识别骑头','尝试向上挥拳','尝试向上挥拳'),moment(3,'持续打不到','转入撤离投石','启动原地投石'),moment(3.8,'应对骑手','后撤，可能中断动作','原地向上投出石头')],
  },
  {
    ...shared,id:'rock',group:'目标与战斗',title:'向移动目标投石',tag:'2.0 重构',
    survivors:[person('S1',[[0,6,0,-2],[8,6,0,4.4]])],
    oldTrack:track([[0,-6,0,0,'throw'],[5,-6,0,0,'wait'],[8,-6,0,0]]),
    newTrack:track([[0,-6,0,0,'throw'],[5,-6,0,0,'wait'],[8,-6,0,0]]),
    rock:{start:2,end:4,old:true,from:[-6,.94,0],to:[6,.4,1.2],oldTo:[6,.15,-.4],arc:2.2},
    old:'旧版也有提前量与跳砖。它使用的出手位置、俯仰和水平提前量计算不够统一，某些横移或高度组合会出现弹道偏差；图中展示偏差分支。',
    current:'从真实石头出手点解低抛轨迹，并结合重力与飞行时间更新目标提前量。强制投石计划的目标不会被最近可视目标覆盖；依然不保证命中突然变向的人。',
    conditions:'本场景的生还者匀速横移，演示弹道与提前量的关系，不是命中率对照。画面中的飞行时间与弧高经过压缩，不能据此校准实服弹道。',
    source:'combat.inc · L4D_TankRock_OnRelease / 低抛解与目标提前量；梯口和边沿跳砖限制。',
    moments:[moment(0,'准备投石','已有预测瞄准','锁定计划目标'),moment(2,'石头出手','近似出手点与旧解算','真实出手点 + 飞行提前量'),moment(4,'目标继续移动','示意：弹道偏离移动目标','示意：瞄准预计到达位置')],
  },
];

export function sampleTrack(frames,t,smooth=false) {
  const i = frames.findIndex((f,j) => j < frames.length-1 && t < frames[j+1].t);
  if(i < 0) return {p:[...frames.at(-1).p],mode:frames.at(-1).mode};
  const a=frames[i], b=frames[i+1], u=Math.max(0,(t-a.t)/(b.t-a.t));
  const p=a.p.map((v,j)=>v+(b.p[j]-v)*u);
  if(smooth){
    const prev=frames[Math.max(0,i-1)].p,next=frames[Math.min(frames.length-1,i+2)].p;
    for(const j of [0,2]){
      const v0=(b.p[j]-prev[j])*.5,v1=(next[j]-a.p[j])*.5;
      p[j]=(2*u**3-3*u**2+1)*a.p[j]+(u**3-2*u**2+u)*v0+(-2*u**3+3*u**2)*b.p[j]+(u**3-u**2)*v1;
    }
  }
  if(a.mode==='hop') {
    // End each illustrative hop segment on the ground; this is intentionally
    // not a frame-for-frame recreation of the engine's vertical integration.
    let start=a.t,end=b.t;
    if(smooth){
      let first=i,last=i;
      while(first>0&&frames[first-1].mode==='hop')first--;
      while(last<frames.length-2&&frames[last+1].mode==='hop')last++;
      start=frames[first].t;end=frames[last+1].t;
    }
    const hops=Math.max(1,Math.round((end-start)/HOP_TIME));
    const phase=((t-start)/(end-start)*hops)%1;
    p[1]+=4*.56*phase*(1-phase);
  } else if(a.mode==='fall') p[1]=a.p[1]+(b.p[1]-a.p[1])*u*u;
  else if(a.mode==='drop-hop') {
    const elapsed=t-a.t;
    p[1]=Math.max(b.p[1],a.p[1]+DROP_VZ*elapsed-3.75*elapsed*elapsed);
  }
  return {p,mode:a.mode==='drop-hop'?'hop':a.mode};
}

const wrap = x => Math.atan2(Math.sin(x),Math.cos(x));
export function makeMovementTrack(scene,version,{difficulty=4,strafe=true}={}) {
  const d=DIFFICULTIES[difficulty], dt=.025, frames=[];
  let x=-9,z=0,heading=0,speed=2.25,hop=-1,hopStart=0,jumping=true;
  for(let t=0;t<=scene.duration+dt/2;t+=dt) {
    const s=sampleTrack(scene.survivors[0].track,t).p;
    const future=sampleTrack(scene.survivors[0].track,Math.min(scene.duration,t+1)).p;
    const distance=Math.hypot(s[0]-x,s[2]-z);
    const nextHop=Math.floor((t+1e-8)/HOP_TIME);
    if(nextHop!==hop) {
      hop=nextHop;hopStart=t;
      jumping=distance>d.stop;
      speed=jumping?Math.min(d.cap,speed+d.impulse*(hop===0?d.first:1)):2.25;
      heading=Math.atan2(future[2]-z,future[0]-x);
      if(version==='2.1'&&strafe&&distance>6) heading+=(hop%2===0?1:-1)*d.angle*Math.PI/180;
    } else if(jumping) {
      let desired=Math.atan2(s[2]-z,s[0]-x);
      if(version==='2.1'&&strafe&&distance>6) desired+=(hop%2===0?1:-1)*d.angle*Math.PI/180;
      const diff=wrap(desired-heading), degrees=Math.abs(diff)*180/Math.PI;
      const min=version==='2.1'?d.minTurn:d.legacyMinTurn;
      const max=version==='old'?135:89;
      if(degrees>=min&&degrees<max) heading+=diff*(1-Math.exp(-dt/.84));
    }
    let mode=jumping?'hop':'run';
    if(!jumping) heading=Math.atan2(s[2]-z,s[0]-x);
    if(distance>.85){x+=Math.cos(heading)*speed*dt;z+=Math.sin(heading)*speed*dt;}else mode='punch';
    const u=jumping?Math.min(1,(t-hopStart)/HOP_TIME):0;
    frames.push({t,p:[x,jumping?4*.56*u*(1-u):0,z],mode,distance,side:version==='2.1'&&strafe&&distance>6?(hop%2===0?1:-1):0});
  }
  return frames;
}

export function buildTrack(scene,version,options) {
  if(scene.dynamic) return makeMovementTrack(scene,version,options);
  return version==='old'?scene.oldTrack:version==='2.0'?(scene.refactorTrack||scene.newTrack):scene.newTrack;
}

export function sampleTank(scene,frames,t) {
  // In the 2.1 corner example, changing waypoints must not manufacture a
  // landing. Keep the jump phase continuous while following the curved route.
  if(!scene.dynamic) return sampleTrack(frames,t,scene.id==='corner'&&frames===scene.newTrack);
  const index=Math.min(frames.length-2,Math.max(0,Math.floor(t/.025)));
  const a=frames[index],b=frames[index+1],u=Math.max(0,Math.min(1,(t-a.t)/(b.t-a.t)));
  return {...a,p:a.p.map((v,j)=>v+(b.p[j]-v)*u)};
}

export function sampleRock(scene,version,t) {
  const r=scene.rock;
  if(!r||t<r.start||t>r.end||(version==='old'&&!r.old)) return null;
  const u=(t-r.start)/(r.end-r.start),end=version==='old'?(r.oldTo||r.to):r.to;
  const p=r.from.map((v,j)=>v+(end[j]-v)*u);
  p[1]+=4*r.arc*u*(1-u);
  return p;
}
