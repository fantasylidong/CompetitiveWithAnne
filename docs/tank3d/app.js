import * as THREE from './vendor/three.module.min.js';
import { OrbitControls } from './vendor/OrbitControls.js';
import { SCENARIOS, DIFFICULTIES, buildTrack, sampleTrack, sampleTank, sampleRock } from './scenarios.js?v=20260916-drop';

const $=id=>document.getElementById(id);
const colors={old:0xbf7741,current:0x238579,survivor:0x477ebd,ground:0xe4ecf1,wall:0xb8c8d2,route:0x7d919e};
const reducedMotion=matchMedia('(prefers-reduced-motion: reduce)').matches;
let selected=SCENARIOS.find(s=>s.id===location.hash.slice(1))||SCENARIOS[0];
let version='2.1',time=0,playing=false,view='perspective',lastFrame=performance.now(),syncing=false,dirty=true;
const panes=[];

function material(color,extra={}){return new THREE.MeshStandardMaterial({color,roughness:.82,metalness:.05,...extra});}
function mesh(parent,geometry,mat,position){
  const obj=new THREE.Mesh(geometry,mat);obj.position.set(...position);obj.castShadow=true;obj.receiveShadow=true;parent.add(obj);return obj;
}
function cube(parent,dim,position,mat){return mesh(parent,new THREE.BoxGeometry(...dim),mat,position);}
function sphere(parent,r,position,mat){return mesh(parent,new THREE.SphereGeometry(r,12,8),mat,position);}
function label(parent,text,position,color='#566f80'){
  const canvas=document.createElement('canvas');canvas.width=256;canvas.height=64;
  const ctx=canvas.getContext('2d');ctx.font='500 40px system-ui';ctx.textAlign='center';ctx.textBaseline='middle';
  ctx.fillStyle=color;ctx.fillText(text,128,32);
  const texture=new THREE.CanvasTexture(canvas);texture.colorSpace=THREE.SRGBColorSpace;
  const sprite=new THREE.Sprite(new THREE.SpriteMaterial({map:texture,depthTest:false,transparent:true}));
  const scale=selected.floor[0]/26;
  sprite.position.set(...position);sprite.scale.set(5.2*scale,1.3*scale,1);parent.add(sprite);return sprite;
}
function ring(parent,r,color,p){
  const obj=new THREE.Mesh(new THREE.RingGeometry(r-.025,r,36),new THREE.MeshBasicMaterial({color,side:THREE.DoubleSide,transparent:true,opacity:.7}));
  obj.rotation.x=-Math.PI/2;obj.position.set(...p);parent.add(obj);return obj;
}
function actor(parent,isTank,color,name){
  const group=new THREE.Group();parent.add(group);
  const skin=material(color),dark=material(isTank?0x354654:0x334f6c),light=material(isTank?0xf1dbbc:0xd6e6f2);
  const body=new THREE.Group();body.scale.setScalar(1.3);group.add(body);
  cube(body,isTank?[.62,.48,.68]:[.28,.33,.29],[0,isTank?.72:.51,0],skin);
  const head=cube(body,isTank?[.3,.3,.34]:[.22,.24,.22],[isTank?.16:.04,isTank?1.03:.81,0],light);
  cube(head,[.025,.045,isTank?.21:.16],[isTank?.153:.113,.018,0],dark);
  const arms=[],legs=[];
  for(const sign of [-1,1]){
    const arm=new THREE.Group();arm.position.set(.015,isTank?.87:.63,sign*(isTank?.45:.22));body.add(arm);
    sphere(arm,isTank?.24:.085,[0,0,0],skin);
    cube(arm,isTank?[.27,.49,.28]:[.11,.3,.12],[.07,isTank?-.23:-.15,0],skin);
    sphere(arm,isTank?.19:.07,[.11,isTank?-.47:-.32,0],light);arms.push(arm);
    const leg=new THREE.Group();leg.position.set(-.06,isTank?.48:.37,sign*(isTank?.2:.09));body.add(leg);
    cube(leg,isTank?[.26,.4,.27]:[.11,.32,.13],[0,-.18,0],dark);
    cube(leg,isTank?[.35,.11,.3]:[.19,.09,.14],[.04,isTank?-.4:-.34,0],dark);legs.push(leg);
  }
  const halo=ring(parent,isTank?.68:.4,color,[0,.022,0]);
  const tag=label(group,name,[0,isTank?2.1:1.75,0],isTank?'#516575':'#396b9e');
  return {group,body,arms,legs,halo,tag};
}
function pose(a,p,t,mode,direction){
  a.group.position.set(...p);if(direction&&Math.hypot(direction[0],direction[2])>.0001)a.group.rotation.y=-Math.atan2(direction[2],direction[0]);
  const active=['run','hop','retreat','climb'].includes(mode),swing=active?Math.sin(t*12)*.55:Math.sin(t*2)*.025;
  a.legs.forEach((leg,i)=>leg.rotation.z=swing*(i?1:-1));
  a.arms.forEach((arm,i)=>{arm.rotation.z=-swing*(i?1:-1)*.7;if(mode==='punch')arm.rotation.z=-.5-Math.max(0,Math.sin(t*7+i))*.9;if(mode==='throw')arm.rotation.z=-1.8;});
  a.body.rotation.z=mode==='hop'?-.12:0;
  a.halo.position.set(p[0],Math.max(.026,p[1]+.025),p[2]);
}
function tube(parent,points,color,opacity=1,radius=.035){
  // Preserve the time-sampled vertices, including stationary intervals. A
  // length-parameterized TubeGeometry would reveal future movement while idle.
  const positions=[],indices=[],sides=5,tangent=new THREE.Vector3(1,0,0);
  for(let i=0;i<points.length;i++){
    const p=new THREE.Vector3(...points[i]);
    const delta=new THREE.Vector3(...points[Math.min(i+1,points.length-1)]).sub(new THREE.Vector3(...points[Math.max(0,i-1)]));
    if(delta.lengthSq()>1e-8)tangent.copy(delta).normalize();
    const axis=Math.abs(tangent.y)>.9?new THREE.Vector3(0,0,1):new THREE.Vector3(0,1,0);
    const normal=new THREE.Vector3().crossVectors(tangent,axis).normalize();
    const binormal=new THREE.Vector3().crossVectors(tangent,normal).normalize();
    for(let j=0;j<sides;j++){
      const angle=j/sides*Math.PI*2;
      const v=p.clone().addScaledVector(normal,Math.cos(angle)*radius).addScaledVector(binormal,Math.sin(angle)*radius);
      positions.push(v.x,v.y,v.z);
      if(i<points.length-1){const a=i*sides+j,b=i*sides+(j+1)%sides;indices.push(a,b,b+sides,a,b+sides,a+sides);}
    }
  }
  const geometry=new THREE.BufferGeometry();geometry.setAttribute('position',new THREE.Float32BufferAttribute(positions,3));geometry.setIndex(indices);
  const object=new THREE.Mesh(geometry,new THREE.MeshBasicMaterial({color,transparent:opacity<1,opacity}));
  parent.add(object);return object;
}
function routeLine(parent,points){
  const geometry=new THREE.BufferGeometry().setFromPoints(points.map(p=>new THREE.Vector3(p[0],p[1]+.035,p[2])));
  const object=new THREE.Line(geometry,new THREE.LineDashedMaterial({color:colors.route,dashSize:.2,gapSize:.17,transparent:true,opacity:.65}));object.computeLineDistances();parent.add(object);return object;
}
function buildPane(id,variant){
  const host=$(id),scene=new THREE.Scene();scene.background=new THREE.Color(0xf4f7fa);
  const renderer=new THREE.WebGLRenderer({antialias:true,alpha:false});renderer.setPixelRatio(Math.min(devicePixelRatio,2));
  renderer.shadowMap.enabled=true;renderer.shadowMap.type=THREE.PCFSoftShadowMap;
  renderer.outputColorSpace=THREE.SRGBColorSpace;renderer.setClearColor(0xf4f7fa);host.append(renderer.domElement);
  renderer.domElement.setAttribute('aria-label',variant==='old'?'重构前动画画面':'重构后动画画面');
  const camera=new THREE.OrthographicCamera(-12,12,10,-10,.1,160);
  scene.add(new THREE.HemisphereLight(0xffffff,0xa1b4c2,1.7));
  const sun=new THREE.DirectionalLight(0xfff6e9,2.0);sun.position.set(-6,17,11);sun.castShadow=true;
  sun.shadow.mapSize.set(1024,1024);Object.assign(sun.shadow.camera,{left:-25,right:25,top:20,bottom:-20,near:.1,far:70});sun.shadow.bias=-.0008;sun.shadow.normalBias=.035;scene.add(sun);
  const controls=new OrbitControls(camera,renderer.domElement);controls.enableDamping=false;controls.minZoom=.5;controls.maxZoom=4;controls.maxPolarAngle=Math.PI/2-.02;controls.target.set(0,.2,0);
  const pane={host,scene,renderer,camera,controls,variant};panes.push(pane);
  controls.addEventListener('change',()=>{
    dirty=true;
    if(syncing||!$('sync').checked)return;
    syncing=true;
    for(const other of panes){if(other===pane)continue;other.camera.position.copy(camera.position);other.camera.up.copy(camera.up);other.camera.zoom=camera.zoom;other.controls.target.copy(controls.target);other.camera.updateProjectionMatrix();other.controls.update();}
    syncing=false;
  });
  renderer.domElement.addEventListener('webglcontextlost',event=>{event.preventDefault();setPlaying(false);$('load-error').hidden=false;$('load-error').textContent='3D 绘图连接中断，请刷新页面恢复场景。';});
  new ResizeObserver(()=>resizePane(pane)).observe(host);
  return pane;
}
function resizePane(pane){
  const w=pane.host.clientWidth,h=pane.host.clientHeight;
  if(!w||!h)return;
  pane.renderer.setSize(w,h,false);
  const width=selected.floor[0]*.6;
  pane.camera.left=-width;pane.camera.right=width;pane.camera.top=width*h/w;pane.camera.bottom=-width*h/w;pane.camera.updateProjectionMatrix();
  dirty=true;
}
function resetCamera(){
  syncing=true;
  for(const pane of panes){
    const c=selected.center;
    pane.controls.target.set(c[0],.45,c[2]);pane.camera.up.set(0,1,0);pane.camera.zoom=1;
    if(view==='top')pane.camera.position.set(c[0],32,c[2]+.01);
    else if(view==='side')pane.camera.position.set(c[0],2.3,c[2]+30);
    else pane.camera.position.set(c[0]+8,18,c[2]+24);
    pane.controls.update();pane.camera.updateProjectionMatrix();resizePane(pane);
  }
  syncing=false;
  document.querySelectorAll('[data-view]').forEach(b=>b.setAttribute('aria-pressed',String(b.dataset.view===view)));
}
function dispose(group){
  if(!group)return;
  const geometries=new Set(),materials=new Set(),textures=new Set();
  group.traverse(o=>{if(o.geometry)geometries.add(o.geometry);for(const m of o.material?(Array.isArray(o.material)?o.material:[o.material]):[]){materials.add(m);if(m.map)textures.add(m.map);}});
  geometries.forEach(g=>g.dispose());textures.forEach(t=>t.dispose());materials.forEach(m=>m.dispose());group.removeFromParent();
}
function buildWorld(pane){
  dispose(pane.world);const world=new THREE.Group();pane.world=world;pane.scene.add(world);
  pane.version=pane.variant==='old'?'old':version;
  pane.track=buildTrack(selected,pane.version,{difficulty:Number($('difficulty').value),strafe:$('strafe').checked});
  const center=selected.center;
  cube(world,[selected.floor[0],.22,selected.floor[1]],[center[0],-.13,center[2]],material(colors.ground));
  const gridPoints=[];const [w,d]=selected.floor;
  for(let x=-w/2;x<=w/2;x++)gridPoints.push(new THREE.Vector3(x+center[0],.003,center[2]-d/2),new THREE.Vector3(x+center[0],.003,center[2]+d/2));
  for(let z=-d/2;z<=d/2;z++)gridPoints.push(new THREE.Vector3(center[0]-w/2,.003,z+center[2]),new THREE.Vector3(center[0]+w/2,.003,z+center[2]));
  world.add(new THREE.LineSegments(new THREE.BufferGeometry().setFromPoints(gridPoints),new THREE.LineBasicMaterial({color:0xcad6df,transparent:true,opacity:.65})));
  for(const b of selected.geometry){
    const mat=material(b.kind==='platform'?0xc3d0d8:colors.wall,b.kind==='platform'?{}:{transparent:true,opacity:b.kind==='ceiling'?.35:.65,depthWrite:false});
    const wall=cube(world,[b.w,b.h,b.d],[b.x,b.y,b.z],mat);
    const edge=new THREE.LineSegments(new THREE.EdgesGeometry(wall.geometry),new THREE.LineBasicMaterial({color:0x90a7b6,transparent:true,opacity:.7}));wall.add(edge);
    if(b.kind==='platform')label(world,`${Math.round(b.h*100)} hu`,[b.x,b.h+.2,b.z-b.d/2+.5]);
    if(b.kind==='ceiling')label(world,'低顶',[b.x,b.y+.75,b.z]);
  }
  for(const l of selected.ladders){
    const ladder=new THREE.Group();ladder.position.set(l.x,0,l.z);if(l.face==='z')ladder.rotation.y=Math.PI/2;world.add(ladder);
    const mat=material(0xb99662);
    for(const z of [-.38,.38])cube(ladder,[.06,l.height,.065],[0,l.height/2,z],mat);
    for(let y=.15;y<l.height;y+=.28)cube(ladder,[.065,.055,.78],[0,y,0],mat);
    label(world,'梯子',[l.x,l.height+.8,l.z]);
  }
  pane.route=new THREE.Group();world.add(pane.route);
  if(selected.route.length>1)routeLine(pane.route,selected.route);
  const points=[];pane.trailSamples=400;
  for(let i=0;i<=pane.trailSamples;i++){const p=sampleTank(selected,pane.track,selected.duration*i/pane.trailSamples).p;points.push([p[0],p[1]+.045,p[2]]);}
  pane.trail=tube(world,points,pane.variant==='old'?colors.old:colors.current,.8,.035);
  pane.tank=actor(world,true,pane.variant==='old'?colors.old:colors.current,'Tank');
  if(selected.id==='rider')pane.tank.body.scale.y=.78;
  pane.survivors=selected.survivors.map(s=>actor(world,false,colors.survivor,s.name));
  pane.rock=mesh(world,new THREE.DodecahedronGeometry(.23,0),material(0x64717d),[0,0,0]);
  pane.rockTrail=new THREE.Group();world.add(pane.rockTrail);
  if(selected.rock&&(pane.version!=='old'||selected.rock.old)){
    const rockPoints=[];for(let i=0;i<=60;i++)rockPoints.push(sampleRock(selected,pane.version,selected.rock.start+(selected.rock.end-selected.rock.start)*i/60));
    routeLine(pane.rockTrail,rockPoints);
  }
  label(world,'每格 100 hu',[center[0]-w/2+2.1,.08,center[2]+d/2-.2]);
  renderPane(pane);
}
function renderPane(pane){
  if(!pane.track)return;
  const tank=sampleTank(selected,pane.track,time),future=sampleTank(selected,pane.track,Math.min(selected.duration,time+.04));
  let heading=future.p.map((v,i)=>v-tank.p[i]);
  if(Math.hypot(heading[0],heading[2])<.001){const s=sampleTrack(selected.survivors[0].track,time).p;heading=s.map((v,i)=>v-tank.p[i]);}
  pose(pane.tank,tank.p,time,tank.mode,heading);
  selected.survivors.forEach((s,i)=>{
    const p=selected.id==='rider'?[tank.p[0],tank.p[1]+s.track[0].p[1],tank.p[2]]:sampleTrack(s.track,time).p;
    pose(pane.survivors[i],p,time,'run',tank.p.map((v,j)=>v-p[j]));
  });
  pane.trail.visible=$('trails').checked;
  pane.trail.geometry.setDrawRange(0,Math.floor(time/selected.duration*pane.trailSamples)*30);
  pane.route.visible=$('paths').checked;
  const rock=sampleRock(selected,pane.version,time);pane.rock.visible=!!rock;
  if(rock){pane.rock.position.set(...rock);pane.rock.rotation.set(time*3,time*2,0);}
  pane.rockTrail.visible=$('trails').checked&&!!selected.rock&&time>=selected.rock.start;
  pane.renderer.render(pane.scene,pane.camera);
}
function updateText(){
  const m=[...selected.moments].reverse().find(m=>m.t<=time)||selected.moments[0];
  $('old-state').textContent=m.old;$('new-state').textContent=version==='2.0'?m.refactor:m.current;
  if(selected.dynamic){
    const fresh=sampleTank(selected,panes[1].track,time);
    if(version==='2.1')$('new-state').textContent=fresh.mode==='punch'?'已经近身，尝试出拳':fresh.side?`${fresh.side>0?'向右':'向左'}侧跳 · 空中平滑跟随`:'距离或开关条件不满足 · 正常追逐';
    $('parameter-note').textContent=`当前目标距离 ${Math.round(fresh.distance*100)} hu · 600 hu 外才允许侧跳`;
  }
  $('time').textContent=`${time.toFixed(2)} / ${selected.duration.toFixed(2)} s`;
  $('timeline').value=String(time);
  document.querySelectorAll('.moment').forEach(b=>b.setAttribute('aria-current',String(Number(b.dataset.time)===m.t)));
}
function render(){panes.forEach(renderPane);updateText();dirty=false;}
function setPlaying(value){playing=value;dirty=true;$('play').textContent=playing?'Ⅱ 暂停':'▶ 播放';$('play').setAttribute('aria-label',playing?'暂停':'播放');lastFrame=performance.now();}
function seek(t){time=Math.max(0,Math.min(selected.duration,t));render();}
function selectScene(id){
  selected=SCENARIOS.find(s=>s.id===id)||SCENARIOS[0];time=0;
  history.replaceState(null,'',`#${selected.id}`);
  $('scene-title').textContent=selected.title;$('scene-group').textContent=`${selected.group} / ${selected.tag}`;
  $('scene-description').textContent=selected.description;$('version-label').textContent=`${version}.0`;
  $('old-explanation').textContent=selected.old;
  $('new-explanation').textContent=version==='2.0'?(selected.refactor||selected.current):selected.current;
  $('condition').textContent=selected.conditions;$('source').textContent=selected.source;
  $('timeline').max=String(selected.duration);$('movement-options').hidden=!selected.dynamic;
  $('strafe').disabled=version!=='2.1';
  $('moments').replaceChildren(...selected.moments.map(m=>{
    const b=document.createElement('button');b.className='moment';b.dataset.time=m.t;b.innerHTML=`<b>${m.t.toFixed(2)}s</b>${m.label}`;b.onclick=()=>{setPlaying(false);seek(m.t);};return b;
  }));
  document.querySelectorAll('.scene-button').forEach(b=>b.setAttribute('aria-current',String(b.dataset.scene===selected.id)));
  panes.forEach(buildWorld);resetCamera();render();
}
let navGroup='';
SCENARIOS.forEach((scene,i)=>{
  if(scene.group!==navGroup){const heading=document.createElement('p');heading.className='nav-group';heading.textContent=scene.group;$('scenarios').append(heading);navGroup=scene.group;}
  const b=document.createElement('button');b.className='scene-button';b.dataset.scene=scene.id;b.innerHTML=`<span>${String(i+1).padStart(2,'0')}</span>${scene.title}`;b.onclick=()=>selectScene(scene.id);$('scenarios').append(b);
});
try{
  buildPane('old-view','old');buildPane('new-view','current');
}catch(error){panes.forEach(p=>p.renderer.dispose());throw error;}
$('play').onclick=()=>{if(time>=selected.duration)seek(0);setPlaying(!playing);};
$('restart').onclick=()=>{seek(0);setPlaying(true);};
$('timeline').addEventListener('input',event=>{setPlaying(false);seek(Number(event.target.value));});
$('version').onchange=()=>{version=$('version').value;selectScene(selected.id);};
for(const id of ['difficulty','strafe'])$(id).onchange=()=>{const saved=time;panes.forEach(buildWorld);seek(saved);};
for(const id of ['trails','paths'])$(id).onchange=render;
$('sync').onchange=()=>{if($('sync').checked)resetCamera();};
$('reset-camera').onclick=resetCamera;
document.querySelectorAll('[data-view]').forEach(b=>b.onclick=()=>{view=b.dataset.view;resetCamera();render();});
document.addEventListener('keydown',event=>{
  if(['INPUT','SELECT','TEXTAREA','BUTTON','SUMMARY','A'].includes(event.target.tagName))return;
  if(event.code==='Space'){event.preventDefault();$('play').click();}
  if(event.code==='ArrowRight'||event.code==='ArrowLeft'){event.preventDefault();setPlaying(false);seek(time+(event.code==='ArrowRight'?.1:-.1));}
});
document.addEventListener('visibilitychange',()=>{lastFrame=performance.now();});
selectScene(selected.id);
// Start paused so both versions share an inspectable initial condition. Reduced
// motion users also retain full manual playback and timeline control.
if(!reducedMotion)seek(2.5);
function animate(now){
  const dt=Math.min(.1,(now-lastFrame)/1000);lastFrame=now;
  if(playing&&!document.hidden){
    time+=dt*Number($('speed').value);
    if(time>=selected.duration){if($('loop').checked)time%=selected.duration;else{time=selected.duration;setPlaying(false);}}
  }
  if(playing||dirty)render();requestAnimationFrame(animate);
}
requestAnimationFrame(animate);
