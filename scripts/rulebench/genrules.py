# -*- coding: utf-8 -*-
# v4 최종 생성 규칙 세트 — 사전/샘플 하드코딩 0
# (Swift 이식의 기준 사양. 모든 상수는 문법적 폐쇄류 또는 표준에서 유도)
import sys, re, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from auto import jamos, compose, N, S, CV, CJ

KS=set(open(os.path.join(os.path.dirname(os.path.abspath(__file__)),'ksx1001.txt'),encoding='utf-8').read())
REV={v:k for k,v in N.items()}; REV.update({v:k for k,v in S.items()})
for (a,b),c in CV.items(): REV[c]=REV[a]+REV[b]
for (a,b),c in CJ.items(): REV[c]=REV[a]+REV[b]
CHO_L='ㄱㄲㄴㄷㄸㄹㅁㅂㅃㅅㅆㅇㅈㅉㅊㅋㅌㅍㅎ'
JUNG_L='ㅏㅐㅑㅒㅓㅔㅕㅖㅗㅘㅙㅚㅛㅜㅝㅞㅟㅠㅡㅢㅣ'
JONG_L=[None]+list('ㄱㄲㄳㄴㄵㄶㄷㄹㄺㄻㄼㄽㄾㄿㅀㅁㅂㅄㅅㅆㅇㅈㅊㅋㅌㅍㅎ')

def ko_to_keys(word):
    out=''
    for ch in word:
        o=ord(ch)
        if 0xAC00<=o<=0xD7A3:
            i=o-0xAC00
            out+=REV[CHO_L[i//588]]+REV[JUNG_L[(i%588)//28]]
            j=JONG_L[i%28]
            if j: out+=REV[j]
        elif ch in REV: out+=REV[ch]
        else: return None
    return out

# ---------- 영어 생성 규칙 ----------
NEVER_DOUBLE=set('hjkqvwxy')            # R-E7 정서법: 겹칠 수 없는 글자
DIGRAPH2=('ch','sh','th','ph','wh','gh','ck','ng','rh')
V5=set('aeiou')
VDG={'ai','au','aw','ay','ea','ee','ei','eu','ew','ey','ie',
     'oa','oe','oi','oo','ou','ow','oy','ue','ui'}      # 표준 모음 이중자 (폐쇄류)
SON={'p':1,'b':1,'t':1,'d':1,'k':1,'g':1,'c':1,'j':1,'q':1,'ch':1,'ck':1,'tch':1,
     'f':2,'v':2,'s':2,'z':2,'x':2,'th':2,'sh':2,'ph':2,'gh':2,'h':2,
     'm':3,'n':3,'ng':3,'l':4,'r':4,'rh':4,'w':5,'y':5,'wh':5}
VOICED_OBS={'b','d','g','v','z','j'}
LIQGLI={'l','r','w','y'}
OBSTR={u for u,s in SON.items() if s<=2}
ONSET_BANS={('t','l'),('d','l'),('th','l'),('s','r'),('p','w'),('b','w'),('f','w'),('v','w'),('m','w')}
INITIAL_SILENT={('k','n'),('g','n'),('w','r'),('p','s'),('p','n'),('p','t'),('m','n'),('t','s')}
APPENDIX={'s','z','th'}                 # R-E5 굴절 접미 자음 (-s, -th)

def cons_units(cl):
    out=[];i=0;n=len(cl)
    while i<n:
        if cl[i:i+3]=='tch': out.append('tch');i+=3;continue
        if cl[i:i+2] in DIGRAPH2: out.append(cl[i:i+2]);i+=2;continue
        c=cl[i]
        if i+1<n and cl[i+1]==c:
            if c in NEVER_DOUBLE: return None
            out.append(c);i+=2;continue
        out.append(c);i+=1
    return out

def onset_ok(us,initial=False):
    n=len(us)
    if n==0: return True
    if n==1: return us[0] not in ('ng','ck','tch') and not (us[0]=='x' and not initial)
    if n==2:
        a,b=us
        if (a,b) in ONSET_BANS: return False
        if initial and (a,b) in INITIAL_SILENT: return True
        if a=='s' and (b in {'p','t','k','c'} or b in {'m','n','f','l','w','q'}): return True
        if a in OBSTR and a not in {'v','x','h','gh','ck','tch','ng','z','j','q'} and b in LIQGLI: return True
        return False
    if n==3:
        a,b,c=us
        return a=='s' and b in {'p','t','k','c'} and c in LIQGLI and (b,c) not in ONSET_BANS
    return False

def core_ok(core):
    # R-E4 공명도 하강 / T1 폐쇄음 연쇄는 무성 t 종결만 / T3 장애음 유성성 일치
    if not core: return True
    if core[0] in ('w','y'): return False
    for x,y in zip(core,core[1:]):
        sx,sy=SON.get(x,0),SON.get(y,0)
        if sx<sy: return False
        if sx==sy and sx==1 and not (y=='t' and x not in VOICED_OBS): return False
        if sx<=2 and sy<=2 and ((x in VOICED_OBS)!=(y in VOICED_OBS)): return False
    return True

def coda_ok(us,final=False):
    if not us: return True
    if us[0]=='h': return False
    if final and len(us)>=2 and us[-1]=='m' and SON.get(us[-2],0)==2:  # R-E9 음절성 -sm/-thm
        return coda_ok(us[:-1],final=False)
    # R-E5 굴절 접미 자음은 단어 끝에만 붙는다. 내부 자음군에 적용하면
    # 불법 폐쇄음 연쇄가 통과한다.
    max_strip = 3 if final else 1
    for strip in range(0,max_strip):
        if strip and (len(us)<strip or any(u not in APPENDIX for u in us[len(us)-strip:])): continue
        core=us[:len(us)-strip] if strip else us
        if core_ok(core): return True
    return False

def english_eval(word):
    """(hard_pass, cost) — cost는 '영어로도 가능하지만 유표적' 위반 수"""
    # R-E14 어중 대문자는 영어 정서법이 아니다. 어두 대문자(고유명사)와
    # 전대문자(약어, l2k에서는 R-D3가 먼저 걸러냄)는 표기 관례지만 어중
    # 대문자는 아니다 — 두벌식 Shift 쌍자모(ㅃㅉㄸㄲㅆㅒㅖ)가 어중에 온
    # 키열(alcuTek=미쳤다, roRnf=개꿀)이 여기서 갈린다.
    if any(c.isupper() for c in word[1:]): return (False,0)
    w=word.lower(); cost=0
    if not (w.isalpha() and w.isascii()): return (False,0)
    if w[-1] in 'jqv': return (False,0)                # R-E6 어말 j/q/v 금지
    if len(w)>=2 and w[-1]=='h' and w[-2] in V5:       # R-E10 어말 모음+h 묵음 → 비용 1
        w=w[:-1]; cost+=1
    w=re.sub(r'(?<=[aeiou])gn','n',w)                  # R-E11 모음 뒤 gn의 묵음 g
    w=w.replace('qu','q')                              # R-E8 qu 단위화
    if 'q' in w:
        i=w.index('q')
        if i+1>=len(w) or w[i+1] not in V5|{'y'}: return (False,cost)
    # R-E13 j 뒤에는 모음이 온다 (y 허용). jam·inject·fjord — 영어 정서법에서
    # j는 언제나 onset이고 뒤에 핵이 따른다. 사전 235,974단어 중 위반은 52개
    # (0.022%)로 전부 raj·hadj·majlis류 차용어다. R-E6 어말 j 금지의 일반화이며,
    # coda `nj`+onset `d` 분절로 살아남던 anjdi(뭐야)류가 여기서 갈린다.
    for i,c in enumerate(w):
        if c=='j' and (i+1>=len(w) or w[i+1] not in V5|{'y'}): return (False,cost)
    # R-E2 모음자 판정 + R-E12 y/w 모음 사이 자음화(활음 onset)
    letters=list(w); vowel_pos=set()
    for i,c in enumerate(letters):
        if c in V5: vowel_pos.add(i)
    changed=True
    while changed:
        changed=False
        for i,c in enumerate(letters):
            if i in vowel_pos: continue
            if c=='y':
                prevv=(i-1) in vowel_pos; nextv=(i+1)<len(letters) and letters[i+1] in V5
                if i==0 and nextv: continue          # 어두 y+모음 = 자음
                if prevv and nextv: continue         # 모음 사이 y = 자음 (abeyant)
                vowel_pos.add(i); changed=True
            elif c=='w':
                prevv=(i-1) in vowel_pos; nextv=(i+1)<len(letters) and letters[i+1] in V5
                if prevv and not nextv:              # 모음+w(+자음/끝) = 이중모음 활음
                    vowel_pos.add(i); changed=True
    if not vowel_pos: return (False,cost)
    segs=[];cur=[];curv=None
    for i,c in enumerate(letters):
        isv=i in vowel_pos
        if curv is None or isv==curv: cur.append(c)
        else: segs.append((curv,''.join(cur)));cur=[c]
        curv=isv
    segs.append((curv,''.join(cur)))
    for idx,(isv,s) in enumerate(segs):
        if isv:
            if len(s)>3: return (False,cost)
            if len(s)==3: cost+=1                                    # R-C2 3중 모음자 = 비용
            if idx==0 and len(s)==2 and s[:2] not in VDG: cost+=1    # R-C1 어두 비표준 모음쌍
            continue
        us=cons_units(s)
        if us is None: return (False,cost)
        first=idx==0; last=idx==len(segs)-1
        if first and last: return (False,cost)
        if first:
            if not onset_ok(us,initial=True): return (False,cost)
        elif last:
            if not coda_ok(us,final=True): return (False,cost)
        else:
            if not any(coda_ok(us[:k]) and onset_ok(us[k:]) for k in range(len(us)+1)): return (False,cost)
    return (True,cost)

# ---------- 한국어 구조 판정 ----------
CONS_KEYS=set('qwertasdfgzxcv')
def max_cons_run(w):
    m=c=0
    for ch in w.lower():
        if ch in CONS_KEYS: c+=1;m=max(m,c)
        else: c=0
    return m
def korean_eval(latin):
    js=jamos(latin)
    if not js: return None
    s,syl,jam=compose(js)
    fully=jam==0 and syl>=1
    return {'text':s,'syl':syl,'fully':fully,
            'ks':fully and all(c in KS for c in s),'run':max_cons_run(latin)}
def K_strong(latin):
    r=korean_eval(latin)
    if not r or not r['fully'] or not r['ks'] or r['run']>3: return False
    return r['syl']>=2 or len(latin)>=3               # R-K4 단음절은 3키(CVC) 이상

# ---------- 방향별 등급 결정 ----------
def explain_l2k(keys):
    """반환: (action, tier|None, rule, replacement|None)  — Swift Rule 이름과 1:1"""
    if len(keys)>=2 and keys.isupper():
        return ('preserve', None, 'acronymConvention', None)
    r=korean_eval(keys)
    if not r:
        return ('preserve', None, 'compositionUnavailable', None)
    if not K_strong(keys):
        return ('preserve', None, 'weakKoreanStructure', None)
    ok,cost=english_eval(keys)
    if not ok:
        return ('correct', 'high', 'koreanStructure', r['text'])
    if cost>=1:
        return ('correct', 'medium', 'englishCostMargin', r['text'])
    return ('preserve', None, 'ambiguousBothValid', None)

def explain_k2l(keys):
    r=korean_eval(keys)
    if not r:
        return ('preserve', None, 'compositionUnavailable', None)
    t=r['text']
    if r['fully'] and r['ks']:
        return ('preserve', None, 'modernKoreanPreserved', None)
    if len(t)>=2 and len(set(t))==1:
        return ('preserve', None, 'expressiveRepetition', None)
    CONS=lambda c: 0x3131<=ord(c)<=0x314E
    all_cons = bool(t) and all(CONS(c) for c in t)
    if all_cons and len(t)>=3 and len(set(t))==len(t):
        return ('preserve', None, 'consonantJamoMash', None)
    ok,cost=english_eval(keys)
    if not ok:
        return ('preserve', None, 'implausibleEnglish', None)
    if cost==0 and not all_cons:
        return ('correct', 'high', 'englishStructure', keys)
    return ('correct', 'medium', 'markedEnglishForm', keys)

def decide_l2k(keys):
    a,t,_,rep = explain_l2k(keys)
    return (t, rep) if a=='correct' else None

def decide_k2l(keys):
    a,t,_,rep = explain_k2l(keys)
    return (t, rep) if a=='correct' else None
