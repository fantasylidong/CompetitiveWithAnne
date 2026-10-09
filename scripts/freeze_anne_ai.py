"""Mechanical SourcePawn private-ConVar freezing; writes no files when imported.

values contains exact textual CVar values, without SourcePawn quoting, keyed by
literal CVar name (preferred) or its assigned handle identifier. Missing values
use the original CreateConVar default. Dynamic names require a handle-key entry.
Only direct scalar assignments are supported. Unsupported private-handle uses
raise FreezeError before a transformed source is returned.
"""
from __future__ import annotations
from dataclasses import dataclass
import math
import re
import struct

class FreezeError(ValueError):
    pass

@dataclass(frozen=True)
class Token:
    text: str
    start: int
    end: int
    kind: str

@dataclass
class Private:
    handle: str
    name: str | None
    value: str
    default: str
    float_value: float
    flags: str
    create_start: int
    create_end: int


def lex(source: str) -> list[Token]:
    out=[];i=0
    while i<len(source):
        if source[i].isspace(): i+=1;continue
        if source.startswith('//',i):
            j=source.find('\n',i);i=len(source) if j<0 else j;continue
        if source.startswith('/*',i):
            j=source.find('*/',i+2)
            if j<0:raise FreezeError('Unterminated block comment')
            i=j+2;continue
        start=i;c=source[i]
        if c in ('"',"'"):
            quote=c;i+=1
            while i<len(source):
                if source[i]=='\\':i+=2;continue
                if source[i]==quote:i+=1;break
                i+=1
            else:raise FreezeError('Unterminated string/character literal')
            out.append(Token(source[start:i],start,i,'string' if quote=='"' else 'char'));continue
        if c.isalpha() or c=='_':
            i+=1
            while i<len(source) and (source[i].isalnum() or source[i]=='_'):i+=1
            out.append(Token(source[start:i],start,i,'identifier'));continue
        if c.isdigit() or (c=='.' and i+1<len(source) and source[i+1].isdigit()):
            m=re.match(r'(?:0[xX][0-9A-Fa-f]+|(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?)',source[i:])
            i+=len(m.group());out.append(Token(source[start:i],start,i,'number'));continue
        op=next((x for x in ['==','!=','<=','>=','+=','-=','*=','/=','&&','||','++','--','<<','>>','&=','|='] if source.startswith(x,i)),None)
        i+=len(op) if op else 1;out.append(Token(source[start:i],start,i,'punct'))
    return out


def unquote(text: str) -> str:
    if not (text.startswith('"') and text.endswith('"')):
        raise FreezeError('Nonliteral string: '+text)
    body=text[1:-1];out=[];i=0
    escapes={'n':'\n','r':'\r','t':'\t','b':'\b','v':'\v','f':'\f','\\':'\\','"':'"',"'":"'",'0':'\0'}
    while i<len(body):
        if body[i]!='\\':out.append(body[i]);i+=1;continue
        i+=1
        if i>=len(body):raise FreezeError('Trailing string escape')
        if body[i] not in escapes:raise FreezeError('Unsupported string escape: \\'+body[i])
        out.append(escapes[body[i]]);i+=1
    value=''.join(out)
    if '\0' in value:raise FreezeError('Embedded NUL cannot be preserved as a CVar string')
    return value


def quote(text: str) -> str:
    if '\0' in text:raise FreezeError('Embedded NUL in supplied value')
    replacements={'\\':'\\\\','"':'\\"','\n':'\\n','\r':'\\r','\t':'\\t','\b':'\\b','\v':'\\v','\f':'\\f'}
    return '"'+''.join(replacements.get(c,c) for c in text)+'"'


def cvar_float(value: str) -> float:
    # ConVar numeric getters use its float/int caches; nonnumeric prefixes are 0.
    match=re.match(r'^[\t\n\r ]*([+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?)',value)
    number=float(match.group(1)) if match else 0.0
    if not math.isfinite(number):raise FreezeError('Nonfinite CVar numeric value')
    return struct.unpack('f', struct.pack('f', number))[0]


def static_number(text: str) -> float:
    text=text.strip()
    if not re.fullmatch(r'[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?',text):
        raise FreezeError('Nonliteral numeric bound: '+text)
    number=float(text)
    if not math.isfinite(number):raise FreezeError('Nonfinite bound')
    return number


def float_literal(number: float) -> str:
    text=format(number,'.9g')
    if '.' not in text and 'e' not in text.lower():text+='.0'
    return text


def call_end(tokens: list[Token], opening: int) -> tuple[int,list[tuple[int,int]]]:
    if tokens[opening].text!='(':raise FreezeError('Expected call opening')
    depth=1;start=opening+1;args=[]
    for i in range(opening+1,len(tokens)):
        text=tokens[i].text
        if text in ('(','[','{'):depth+=1
        elif text in (')',']','}'):
            depth-=1
            if depth==0:
                if i>start:args.append((start,i))
                return i,args
        elif text==',' and depth==1:args.append((start,i));start=i+1
    raise FreezeError('Unclosed call')


def arg_text(source: str,tokens: list[Token],span: tuple[int,int]) -> str:
    begin,end=span
    if begin==end:return ''
    return source[tokens[begin].start:tokens[end-1].end]


def freeze_source_with_report(source: str, values: dict[str,str]) -> tuple[str,dict]:
    tokens=lex(source)
    for i,t in enumerate(tokens):
        if t.text=='ctrlchar' and i and tokens[i-1].text=='pragma':
            raise FreezeError('#pragma ctrlchar is unsupported: string escaping must be reviewed')
    privates={};edits=[];report={'private_cvars':[],'replacements':[],'deleted_interfaces':[],'bounds_policy':'defaults are not clamped; explicit configuration writes honor min/max; numeric cache is float32; clamped GetString mismatches are rejected','unused_value_keys':[]}
    def at(t):return source.count('\n',0,t.start)+1
    def edit(begin,end,replacement,reason):
        edits.append((begin,end,replacement));report['replacements'].append({'line':source.count('\n',0,begin)+1,'reason':reason})
    for i,t in enumerate(tokens):
        if t.text!='CreateConVar' or t.kind!='identifier' or i+1>=len(tokens) or tokens[i+1].text!='(':continue
        end,args=call_end(tokens,i+1)
        if i<2 or tokens[i-1].text!='=' or tokens[i-2].kind!='identifier':
            raise FreezeError(f'line {at(t)}: CreateConVar is not assigned directly to a scalar handle')
        handle=tokens[i-2].text
        if handle in privates:raise FreezeError('Multiple CreateConVar assignments: '+handle)
        if end+1>=len(tokens) or tokens[end+1].text!=';':
            raise FreezeError(f'line {at(t)}: CreateConVar assignment is not a standalone statement')
        raw=[arg_text(source,tokens,a).strip() for a in args]
        if len(raw)<2:raise FreezeError('CreateConVar missing name/default')
        name=unquote(raw[0]) if len(tokens[args[0][0]:args[0][1]])==1 and tokens[args[0][0]].kind=='string' else None
        if name is None and handle not in values:
            raise FreezeError(f'line {at(t)}: dynamic CVar name {raw[0]} needs values[{handle!r}]')
        default=unquote(raw[1]);value=values[name] if name in values else values.get(handle,default)
        if not isinstance(value,str):raise FreezeError('CVar value must be a string: '+str(name))
        numeric=cvar_float(value);clamped=numeric
        # L4D2 ConVar::Create stores defaults without clamping. Only subsequent
        # configuration writes call ClampValue; preserve even erroneous bounds.
        # https://github.com/alliedmodders/hl2sdk/blob/l4d2/tier1/convar.cpp
        configured = name in values or handle in values
        for enabled_index,bound_index,lower in [(4,5,True),(6,7,False)]:
            if len(raw)>enabled_index:
                enabled=raw[enabled_index]
                if enabled not in ('true','false','0','1'):raise FreezeError('Dynamic bound-enabled expression: '+enabled)
                if configured and enabled in ('true','1'):
                    if len(raw)<=bound_index:raise FreezeError('Missing numeric bound')
                    bound=static_number(raw[bound_index]);clamped=max(clamped,bound) if lower else min(clamped,bound)
        start=tokens[i-2].start
        if i>=3 and tokens[i-3].text=='ConVar':start=tokens[i-3].start
        p=Private(handle,name,value,default,clamped,raw[3] if len(raw)>3 else 'FCVAR_NONE',start,tokens[end+1].end)
        privates[handle]=p
        edit(p.create_start,p.create_end,'',f'remove private CreateConVar {name or handle}')
        report['private_cvars'].append({'handle':handle,'name':name,'value':value,'default':default,'numeric':clamped,'numeric_clamped':clamped!=numeric,'line':at(t)})
    report['unused_value_keys']=sorted(set(values)-{p.name for p in privates.values()}-set(privates))
    if not privates:return source,report
    def covered(t):return any(a<=t.start and t.end<=b for a,b,_ in edits)
    def stmt_end(begin,end):
        if end+1>=len(tokens) or tokens[end+1].text!=';':raise FreezeError(f'line {at(tokens[begin])}: private metadata call used as expression')
        # Only direct statement calls: a preceding ')' may be an unbraced if.
        prev=tokens[begin-1].text if begin else None
        if prev not in (None,';','{','}'):
            raise FreezeError(f'line {at(tokens[begin])}: conditional/private metadata call requires manual review')
        return tokens[end+1].end
    def get_value(p,kind):
        if kind=='BoolValue':return 'true' if int(p.float_value)!=0 else 'false'
        if kind=='IntValue':
            n=int(p.float_value)
            if not -(2**31)<=n<2**31:raise FreezeError('ConVar integer outside signed cell range: '+p.handle)
            return '('+str(n)+')'
        return '('+float_literal(p.float_value)+')'
    def string_call(p,args,kind):
        if len(args)!=2:raise FreezeError('String getter signature requires two output arguments')
        if p.float_value!=cvar_float(p.value):
            raise FreezeError(f'{p.handle}: GetString value crosses a numeric bound; exact engine string representation needs explicit normalization')
        return 'strcopy('+args[0]+', '+args[1]+', '+quote(p.value)+')'
    function_getters={'GetConVarBool':'BoolValue','GetConVarInt':'IntValue','GetConVarFloat':'FloatValue'}
    metadata_setters={'SetConVarFlags','HookConVarChange','UnhookConVarChange','AddConVarChangeHook','RemoveConVarChangeHook'}
    for i,t in enumerate(tokens):
        if covered(t):continue
        if t.text in set(function_getters)|{'GetConVarString','GetConVarFlags','CvarFloat','CvarInt'}|metadata_setters:
            if i+1>=len(tokens) or tokens[i+1].text!='(':continue
            end,args=call_end(tokens,i+1)
            if not args:continue
            a,b=args[0]
            if b-a!=1 or tokens[a].text not in privates:continue
            p=privates[tokens[a].text]
            if t.text in ('CvarFloat','CvarInt'):
                if len(args)!=2:raise FreezeError('Unexpected optional getter arguments')
                replacement=get_value(p,'FloatValue' if t.text=='CvarFloat' else 'IntValue')
            elif t.text in function_getters:
                if len(args)!=1:raise FreezeError('Unexpected numeric getter arguments')
                replacement=get_value(p,function_getters[t.text])
            elif t.text=='GetConVarString':
                replacement=string_call(p,[arg_text(source,tokens,a) for a in args[1:]],t.text)
            elif t.text=='GetConVarFlags':replacement='('+p.flags+')'
            else:
                stop=stmt_end(i,end);edit(t.start,stop,'','remove private '+t.text);report['deleted_interfaces'].append(t.text);continue
            edit(t.start,tokens[end].end,replacement,'replace private '+t.text);continue
        if t.text in privates and i+2<len(tokens) and tokens[i+1].text in ('==','!=') and tokens[i+2].text in ('null','INVALID_HANDLE'):
            edit(t.start,tokens[i+2].end,'true' if tokens[i+1].text=='!=' else 'false','fold successful private handle creation')
            continue
        if t.text in privates and i and tokens[i-1].text=='!' and tokens[i+1].text!='.':
            edit(tokens[i-1].start,t.end,'false','fold successful private handle creation')
            continue
        if t.text not in privates or t.kind!='identifier' or i+2>=len(tokens) or tokens[i+1].text!='.':continue
        p=privates[t.text];method=tokens[i+2].text
        if method in ('BoolValue','IntValue','FloatValue','Flags'):
            nxt=tokens[i+3].text if i+3<len(tokens) else ''
            prev=tokens[i-1].text if i else ''
            if nxt in ('=','+=','-=','*=','/=','++','--','&=','|=') or prev in ('++','--'):
                if method=='Flags' and nxt=='=':
                    end=i+4
                    while end<len(tokens) and tokens[end].text!=';':end+=1
                    if end==len(tokens):raise FreezeError('Unterminated Flags assignment')
                    stop=stmt_end(i,end-1);edit(t.start,stop,'','remove private Flags assignment');continue
                raise FreezeError(f'line {at(t)}: private CVar numeric write must be reviewed: {p.handle}.{method}')
            replacement='('+p.flags+')' if method=='Flags' else get_value(p,method)
            edit(t.start,tokens[i+2].end,replacement,'replace private .'+method)
        elif i+3<len(tokens) and tokens[i+3].text=='(':
            end,args=call_end(tokens,i+3);raw=[arg_text(source,tokens,a) for a in args]
            if method=='GetString':edit(t.start,tokens[end].end,string_call(p,raw,method),'replace private GetString')
            elif method in ('AddChangeHook','RemoveChangeHook'):
                stop=stmt_end(i,end);edit(t.start,stop,'','remove private '+method);report['deleted_interfaces'].append(method)
            else:raise FreezeError(f'line {at(t)}: unsupported private method {p.handle}.{method}')
    # Permit only declarations; every other surviving handle token is an error.
    declaration_tokens=set()
    for i,t in enumerate(tokens):
        if t.text!='ConVar':continue
        # A ConVar typed function parameter is not a global declaration; scalar
        # declaration runs end at ';', stopping at function delimiters.
        j=i+1
        while j<len(tokens) and tokens[j].text not in (';','(',')','{','}'):
            if tokens[j].text in privates:declaration_tokens.add(j)
            j+=1
        # Remove the now-unused private declarations, retaining engine handles.
        if j<len(tokens) and tokens[j].text==';' and any(k in declaration_tokens for k in range(i+1,j)) and not covered(t):
            parts=[];begin=i+1
            for k in range(i+1,j+1):
                if tokens[k].text not in (',',';'):continue
                if tokens[begin].text not in privates:
                    parts.append(source[tokens[begin].start:tokens[k-1].end])
                begin=k+1
            edit(t.start,tokens[j].end,'ConVar '+', '.join(parts)+';' if parts else '', 'remove private handle declarations')
    leftovers=[]
    for i,t in enumerate(tokens):
        if t.kind=='identifier' and t.text in privates and not covered(t) and i not in declaration_tokens:
            leftovers.append(f'line {at(t)}: {t.text}: '+source[max(0,t.start-35):min(len(source),t.end+50)].replace('\n',' '))
    if leftovers:raise FreezeError('Unsupported remaining private-handle uses:\n'+'\n'.join(leftovers))
    ordered=sorted(edits,key=lambda e:(e[0],e[1]))
    for a,b in zip(ordered,ordered[1:]):
        if a[1]>b[0]:raise FreezeError('Overlapping transformations; manual review required')
    result=source
    for begin,end,replacement in reversed(ordered):result=result[:begin]+replacement+result[end:]
    report['transformed_private_count']=len(privates)
    return result,report


def freeze_source(source: str, values: dict[str,str]) -> str:
    return freeze_source_with_report(source,values)[0]


def _selftest():
    source='''// CreateConVar("decoy", "99")\nConVar c; ConVar engine;\npublic void Start() {\n c = CreateConVar("test", "2.75", "quoted\\\"note");\n engine = FindConVar("z_lunge_interval");\n c.AddChangeHook(Change);\n engine.AddChangeHook(Change);\n float f=c.FloatValue; int i=GetConVarInt(c); bool b=c.BoolValue;\n char out[64]; c.GetString(out, sizeof(out));\n engine.FloatValue = f;\n PrintToServer("c.FloatValue // unchanged");\n}'''
    result,report=freeze_source_with_report(source,{'test':'-2.75'})
    assert 'float f=(-2.75)' in result and 'int i=(-2)' in result and 'bool b=true' in result
    assert 'strcopy(out, sizeof(out), "-2.75")' in result
    assert 'engine = FindConVar("z_lunge_interval")' in result and 'engine.FloatValue = f' in result
    assert 'engine.AddChangeHook(Change)' in result and 'c.AddChangeHook' not in result
    assert '// CreateConVar("decoy", "99")' in result and '"c.FloatValue // unchanged"' in result
    string_source='ConVar s; void Start(){ s=CreateConVar("str", "a"); char out[99]; GetConVarString(s,out,sizeof(out)); }'
    result=freeze_source(string_source,{'str':'a"b\\c\n中文,40'})
    assert 'strcopy(out, sizeof(out), "a\\"b\\\\c\\n中文,40")' in result
    for value,expected in [('0.5','false'),('-0.5','false'),('1.5','true'),('-1.5','true'),('abc','false')]:
        result=freeze_source('ConVar c; void F(){ c=CreateConVar("x","1"); bool b=c.BoolValue; }',{'x':value})
        assert 'bool b='+expected in result
    bounded='ConVar c; void F(){ c=CreateConVar("x","1","",0,true,0.0,true,3.0); float f=c.FloatValue; }'
    assert 'float f=(3.0)' in freeze_source(bounded,{'x':'20'})
    bad_default=bounded.replace('"x","1"','"x","1000"')
    assert 'float f=(1000.0)' in freeze_source(bad_default,{})
    assert 'if(true)' in freeze_source('ConVar c; void F(){ c=CreateConVar("x","1"); if(c != null) {} }',{})
    errors=['c.IntValue=3;','delete c;','UseHandle(c);','c.GetBounds(ConVarBound_Upper,out);','c.SetBounds(ConVarBound_Upper,true,8.0);']
    for expr in errors:
        try:freeze_source('ConVar c; void F(){ c=CreateConVar("x","1"); '+expr+' }',{})
        except FreezeError:pass
        else:raise AssertionError('Expected leftover/write error: '+expr)
    print('selftest passed: numeric, integer bool, bounds, string escaping, comments/literals, engine preservation, private hooks and unsupported-use rejection')

if __name__=='__main__':_selftest()
