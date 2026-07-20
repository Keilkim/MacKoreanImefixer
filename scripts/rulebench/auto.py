# -*- coding: utf-8 -*-
import sys
# 두벌식 매핑 (KeycodeToJamoMap.swift 와 동일)
N = {'q':'ㅂ','w':'ㅈ','e':'ㄷ','r':'ㄱ','t':'ㅅ','a':'ㅁ','s':'ㄴ','d':'ㅇ','f':'ㄹ','g':'ㅎ',
     'z':'ㅋ','x':'ㅌ','c':'ㅊ','v':'ㅍ','y':'ㅛ','u':'ㅕ','i':'ㅑ','o':'ㅐ','p':'ㅔ',
     'h':'ㅗ','j':'ㅓ','k':'ㅏ','l':'ㅣ','b':'ㅠ','n':'ㅜ','m':'ㅡ'}
S = {'Q':'ㅃ','W':'ㅉ','E':'ㄸ','R':'ㄲ','T':'ㅆ','O':'ㅒ','P':'ㅖ'}
VOW=set('ㅏㅐㅑㅒㅓㅔㅕㅖㅗㅘㅙㅚㅛㅜㅝㅞㅟㅠㅡㅢㅣ')
CHO='ㄱㄲㄴㄷㄸㄹㅁㅂㅃㅅㅆㅇㅈㅉㅊㅋㅌㅍㅎ'
JUNG='ㅏㅐㅑㅒㅓㅔㅕㅖㅗㅘㅙㅚㅛㅜㅝㅞㅟㅠㅡㅢㅣ'
JONG=[None]+list('ㄱㄲㄳㄴㄵㄶㄷㄹㄺㄻㄼㄽㄾㄿㅀㅁㅂㅄㅅㅆㅇㅈㅊㅋㅌㅍㅎ')
CV={('ㅗ','ㅏ'):'ㅘ',('ㅗ','ㅐ'):'ㅙ',('ㅗ','ㅣ'):'ㅚ',('ㅜ','ㅓ'):'ㅝ',
    ('ㅜ','ㅔ'):'ㅞ',('ㅜ','ㅣ'):'ㅟ',('ㅡ','ㅣ'):'ㅢ'}
CJ={('ㄱ','ㅅ'):'ㄳ',('ㄴ','ㅈ'):'ㄵ',('ㄴ','ㅎ'):'ㄶ',('ㄹ','ㄱ'):'ㄺ',('ㄹ','ㅁ'):'ㄻ',
    ('ㄹ','ㅂ'):'ㄼ',('ㄹ','ㅅ'):'ㄽ',('ㄹ','ㅌ'):'ㄾ',('ㄹ','ㅍ'):'ㄿ',('ㄹ','ㅎ'):'ㅀ',('ㅂ','ㅅ'):'ㅄ'}

def jamos(word):
    out=[]
    for ch in word:
        if ch in S: out.append(S[ch])
        elif ch.lower() in N: out.append(N[ch.lower()])
        else: return None
    return out

def compose(js):
    """두벌식 오토마톤. 반환: (결과문자열, 완성음절수, 낱자모수)"""
    res=[]; cho=jung=jong=None; jongf=None
    def flush():
        nonlocal cho,jung,jong,jongf
        if cho is not None and jung is not None:
            ci=CHO.index(cho); vi=JUNG.index(jung); ti=JONG.index(jong) if jong else 0
            res.append(chr(0xAC00+ci*588+vi*28+ti))
        elif cho is not None: res.append(cho)
        elif jung is not None: res.append(jung)
        cho=jung=jong=jongf=None
    for j in js:
        if j in VOW:
            if jong is not None:
                # 종성이 다음 음절 초성으로 이동
                if jongf is not None and jong!=jongf and cho is not None:
                    mv=[k for k,v in CJ.items() if v==jong][0]
                    keep,move=mv[0],mv[1]
                    jong=keep
                    ci=CHO.index(cho);vi=JUNG.index(jung);ti=JONG.index(jong)
                    res.append(chr(0xAC00+ci*588+vi*28+ti))
                    cho,jung,jong,jongf=move,j,None,None
                else:
                    mv=jong; jong=None; flush(); cho,jung=mv,j
            elif jung is not None:
                if (jung,j) in CV: jung=CV[(jung,j)]
                else: flush(); cho,jung=None,j
            elif cho is not None: jung=j
            else: flush(); jung=j
        else:
            if jung is None:
                if cho is not None: flush()
                cho=j
            elif jong is None:
                if cho is None:
                    flush(); cho=j
                elif j in JONG: jong=j; jongf=j
                else: flush(); cho=j
            else:
                if (jongf,j) in CJ: jong=CJ[(jongf,j)]
                else: flush(); cho=j
    flush()
    s=''.join(res)
    syl=sum(1 for c in s if 0xAC00<=ord(c)<=0xD7A3)
    jam=sum(1 for c in s if 0x3131<=ord(c)<=0x318E)
    return s,syl,jam
