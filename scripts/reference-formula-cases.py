#!/usr/bin/env python3
"""Write the ShapeSheet formula reference case set (WP-15-T02/T03).

Every case is evaluated by Visio 2019 and by MacVisio against the same probe drawing (two
rectangles; Sheet.1 carries typed User/Prop cells and text, Sheet.2 hosts User.Probe).
"""
import json, sys
from pathlib import Path

SHAPES = [
    {"key": "A", "rect": [1, 1, 3, 2], "text": "Hello World", "cells": {
        "User.Num": "3.5", "User.Neg": "-2.25", "User.Str": "\"abc\"", "User.Len": "25.4 mm",
        "User.Ang": "30 deg", "User.Flag": "TRUE", "User.Zero": "0", "User.Color": "RGB(10,20,30)",
        "Prop.Cost": "12.5", "Prop.Name": "\"Widget\""}},
    {"key": "B", "rect": [4, 4, 5, 6], "text": "Probe", "cells": {"User.Local": "7"}},
    {"key": "C", "rect": [1, 7, 4, 8], "text": "Measured text in Arial", "cells": {"Char.Font": "FONT(\"Arial\")", "Char.Size": "12 pt"}},
    {"key": "D", "rect": [5, 7, 7, 8], "text": "Two\nlines", "cells": {"Char.Font": "FONT(\"Arial\")", "Char.Size": "18 pt"}},
] + [{"key": f"M{i}", "rect": [0.5, 9 + i * 0.1, 1, 9.05 + i * 0.1], "text": t, "cells": {"Char.Font": "FONT(\"Arial\")", "Char.Size": f"{size} pt",
      "LeftMargin": "0 pt", "RightMargin": "0 pt", "TopMargin": "0 pt", "BottomMargin": "0 pt"}}
     for i, (t, size) in enumerate([("x", 12), ("x", 24), ("x", 48), ("xxxxxxxxxx", 12), ("xxxxxxxxxx", 24), ("W", 36), ("iiiiiiiiii", 12), ("x x", 12), ("Measured text in Arial", 12)])]

def fn(name, *formulas):
    return [(f"{name}-{i+1}", f) for i, f in enumerate(formulas)]

CASES = []
CASES += fn("ABS", "ABS(-3.5)", "ABS(3)", "ABS(-2 in)", "ABS(Sheet.1!User.Neg)", "ABS(\"x\")")
CASES += fn("ACOS", "ACOS(0.5)", "ACOS(1)", "ACOS(-1)", "ACOS(2)")
CASES += fn("AND", "AND(1,1)", "AND(1,0)", "AND(TRUE,TRUE,TRUE)", "AND(Sheet.1!User.Flag,1)", "AND(2,3)")
CASES += fn("ANG360", "ANG360(-30 deg)", "ANG360(400 deg)", "ANG360(-1)", "ANG360(0)")
CASES += fn("ASIN", "ASIN(0.5)", "ASIN(-1)", "ASIN(1.5)")
CASES += fn("ATAN", "ATAN(1)", "ATAN(-1)", "ATAN(0)")
CASES += fn("ATAN2", "ATAN2(1,1)", "ATAN2(-1,0)", "ATAN2(0,-1)", "ATAN2(0,0)", "ATAN2(2 in,1 in)")
CASES += fn("BITAND", "BITAND(12,10)", "BITAND(7,0)", "BITAND(-1,5)", "BITAND(5.7,3)")
CASES += fn("BITOR", "BITOR(12,10)", "BITOR(0,0)", "BITOR(5.7,8)")
CASES += fn("BITXOR", "BITXOR(12,10)", "BITXOR(5,5)", "BITXOR(5.7,1)")
CASES += fn("BKGPAGENAME", "BKGPAGENAME()", "BKGPAGENAME(0)")
CASES += fn("BLUE", "BLUE(RGB(1,2,3))", "BLUE(Sheet.1!User.Color)", "BLUE(4)", "BLUE(\"#102030\")")
CASES += fn("BOUND", "BOUND(5,0,0,10)", "BOUND(15,0,0,10)", "BOUND(-5,0,0,10)", "BOUND(5,1,0,10)", "BOUND(15,0,0,10,20,30)")
CASES += fn("CEILING", "CEILING(2.1)", "CEILING(-2.1)", "CEILING(2.1,0.5)", "CEILING(7,3)", "CEILING(2.1 in,0.25 in)", "CEILING(5,0)")
CASES += fn("CHAR", "CHAR(65)", "CHAR(97)", "CHAR(0)", "CHAR(300)", "LEN(CHAR(13))")
CASES += fn("CONCATENATE", "CONCATENATE(\"a\",\"b\")", "CONCATENATE(\"x\",1,2)", "CONCATENATE(Sheet.1!User.Str,\"!\")")
CASES += fn("COS", "COS(0)", "COS(60 deg)", "COS(PI())")
CASES += fn("DATE", "DATE(2026,10,25)", "DATE(2026,13,1)", "DATE(2026,2,30)", "DATE(1899,12,30)", "DATE(2026,10,25)+1")
CASES += fn("DEG", "DEG(PI())", "DEG(1)", "DEG(90 deg)")
CASES += fn("EXP", "EXP(0)", "EXP(1)", "EXP(-1)")
CASES += fn("FIELDPICTURE", "FIELDPICTURE(0)", "FIELDPICTURE(20)", "FIELDPICTURE(37)", "FIELDPICTURE(99)")
CASES += fn("FIND", "FIND(\"lo\",\"Hello\")", "FIND(\"L\",\"Hello\")", "FIND(\"l\",\"Hello\",4)", "FIND(\"z\",\"Hello\")", "FIND(\"\",\"Hello\")", "FIND(\"l\",\"Hello\",0)")
CASES += fn("FLOOR", "FLOOR(2.9)", "FLOOR(-2.1)", "FLOOR(2.9,0.5)", "FLOOR(7,3)", "FLOOR(2.9 in,0.25 in)")
CASES += fn("FORMAT", "FORMAT(3.14159,\"0.00\")", "FORMAT(1234.5,\"#,##0.0\")", "FORMAT(0.25,\"0%\")", "FORMAT(2 in,\"0.0 u\")",
            "FORMAT(DATE(2026,10,25),\"yyyy-mm-dd\")", "FORMAT(\"text\",\"@\")", "FORMAT(-5,\"0;(0)\")")
CASES += fn("GREEN", "GREEN(RGB(1,2,3))", "GREEN(Sheet.1!User.Color)")
CASES += fn("GUARD", "GUARD(5)", "GUARD(Sheet.1!Width*2)", "GUARD(\"s\")")
CASES += fn("HSL", "HSL(0,240,120)", "HSL(80,240,120)", "RED(HSL(0,240,120))", "GREEN(HSL(80,240,120))")
CASES += fn("HUE", "HUE(RGB(255,0,0))", "HUE(RGB(0,255,0))", "HUE(RGB(0,0,255))", "HUE(RGB(128,128,128))")
CASES += fn("ID", "ID()", "Sheet.1!ID()")
CASES += fn("IF", "IF(1,2,3)", "IF(0,2,3)", "IF(1>2,\"a\",\"b\")", "IF(Sheet.1!User.Num>3,Sheet.1!Width,0)", "IF(1,2)")
CASES += fn("IFERROR", "IFERROR(1/0,7)", "IFERROR(5,7)", "IFERROR(ACOS(2),\"bad\")")
CASES += fn("INDEX", "INDEX(1,\"a;b;c\")", "INDEX(0,\"a;b;c\")", "INDEX(5,\"a;b;c\")", "INDEX(1,\"a|b|c\",\"|\")", "INDEX(-1,\"a;b\")", "INDEX(1,\"a;b\",\";\",\"none\")")
CASES += fn("INT", "INT(2.7)", "INT(-2.7)", "INT(3 in)")
CASES += fn("ISTHEMED", "ISTHEMED()")
CASES += fn("LEFT", "LEFT(\"Hello\",2)", "LEFT(\"Hello\")", "LEFT(\"Hello\",10)", "LEFT(\"Hello\",0)", "LEFT(\"Hello\",-1)")
CASES += fn("LEN", "LEN(\"Hello\")", "LEN(\"\")", "LEN(Sheet.1!User.Str)", "LEN(123)")
CASES += fn("LN", "LN(1)", "LN(EXP(2))", "LN(0)", "LN(-1)")
CASES += fn("LOG10", "LOG10(1000)", "LOG10(1)", "LOG10(0)")
CASES += fn("LOWER", "LOWER(\"HeLLo\")", "LOWER(\"ÄÖÜ\")", "LOWER(5)")
CASES += fn("LUM", "LUM(RGB(255,0,0))", "LUM(RGB(255,255,255))", "LUM(RGB(0,0,0))")
CASES += fn("LUMDIFF", "LUMDIFF(RGB(255,255,255),RGB(0,0,0))", "LUMDIFF(RGB(10,20,30),RGB(10,20,30))")
CASES += fn("MAX", "MAX(1,5,3)", "MAX(-1,-5)", "MAX(2 in,3 cm)", "MAX(7)")
CASES += fn("MID", "MID(\"Hello\",2,3)", "MID(\"Hello\",0,2)", "MID(\"Hello\",4,10)", "MID(\"Hello\",9,2)")
CASES += fn("MIN", "MIN(1,5,3)", "MIN(-1,-5)", "MIN(2 in,3 cm)")
CASES += fn("MODULUS", "MODULUS(7,3)", "MODULUS(-7,3)", "MODULUS(7,-3)", "MODULUS(7.5,2)", "MODULUS(7,0)")
CASES += fn("NOT", "NOT(1)", "NOT(0)", "NOT(5)", "NOT(TRUE)")
CASES += fn("NURBS", "NURBS(1,3,0,0,0,0,1,1,1,0.5,1,1,1,1)")
CASES += fn("OPENTEXTWIN", "OPENTEXTWIN()")
CASES += fn("OR", "OR(0,0)", "OR(0,1)", "OR(FALSE,FALSE,TRUE)")
CASES += fn("PAGECOUNT", "PAGECOUNT()", "PAGECOUNT(TRUE)")
CASES += fn("PAGENAME", "PAGENAME()", "PAGENAME(0)", "PAGENAME(1)")
CASES += fn("PAGENUMBER", "PAGENUMBER()", "PAGENUMBER(TRUE)")
CASES += fn("PI", "PI()", "PI()*2")
CASES += fn("POLYLINE", "POLYLINE(0,0,0,0,1,1,1,0)")
CASES += fn("POW", "POW(2,10)", "POW(2,-1)", "POW(-8,1/3)", "POW(0,0)", "POW(2 in,2)")
CASES += fn("RAD", "RAD(180)", "RAD(90 deg)")
CASES += fn("RED", "RED(RGB(1,2,3))", "RED(Sheet.1!User.Color)", "RED(2)")
CASES += fn("REF", "REF()")
CASES += fn("REPLACE", "REPLACE(\"Hello\",2,3,\"ipp\")", "REPLACE(\"Hello\",1,0,\">\")", "REPLACE(\"Hello\",9,1,\"!\")", "REPLACE(\"Hello\",0,1,\"x\")")
CASES += fn("REPT", "REPT(\"ab\",3)", "REPT(\"ab\",0)", "REPT(\"ab\",-1)", "REPT(\"ab\",2.7)")
CASES += fn("RGB", "RGB(10,20,30)", "RGB(300,0,0)", "RGB(-1,0,0)", "RGB(1.6,0,0)")
CASES += fn("RIGHT", "RIGHT(\"Hello\",2)", "RIGHT(\"Hello\")", "RIGHT(\"Hello\",10)", "RIGHT(\"Hello\",-1)")
CASES += fn("ROUND", "ROUND(2.345,2)", "ROUND(2.5,0)", "ROUND(-2.5,0)", "ROUND(1234,-2)", "ROUND(2.345 in,1)", "ROUND(0.125,2)")
CASES += fn("SAT", "SAT(RGB(255,0,0))", "SAT(RGB(128,128,128))", "SAT(RGB(200,100,50))")
CASES += fn("SETATREF", "SETATREF(Sheet.2!User.Local)", "SETATREF(Sheet.2!User.Local,SETATREFEVAL(SETATREFEXPR(0)*2))")
CASES += fn("SETATREFEVAL", "SETATREFEVAL(5)")
CASES += fn("SETATREFEXPR", "SETATREFEXPR(5)", "SETATREFEXPR()")
CASES += fn("GETREF", "GETREF(Sheet.1!Width)")
CASES += fn("SHAPETEXT", "SHAPETEXT(Sheet.1!TheText)", "SHAPETEXT(Sheet.2!TheText)", "LEN(SHAPETEXT(Sheet.1!TheText))")
CASES += fn("SIGN", "SIGN(-3)", "SIGN(0)", "SIGN(2 in)")
CASES += fn("SIN", "SIN(0)", "SIN(30 deg)", "SIN(PI()/2)")
CASES += fn("SQRT", "SQRT(16)", "SQRT(2)", "SQRT(-1)", "SQRT(4 in)")
CASES += fn("STRSAME", "STRSAME(\"abc\",\"ABC\")", "STRSAME(\"abc\",\"ABC\",TRUE)", "STRSAME(\"abc\",\"abd\")")
CASES += fn("STRSAMEEX", "STRSAMEEX(\"abc\",\"ABC\",0,1)", "STRSAMEEX(\"abc\",\"ABC\",0,0)")
CASES += fn("SUBSTITUTE", "SUBSTITUTE(\"a-b-c\",\"-\",\"+\")", "SUBSTITUTE(\"a-b-c\",\"-\",\"+\",2)", "SUBSTITUTE(\"aaa\",\"a\",\"\")", "SUBSTITUTE(\"abc\",\"\",\"x\")")
CASES += fn("SUM", "SUM(1,2,3)", "SUM(1 in,2 cm)", "SUM(-1)", "SUM(Sheet.1!User.Num,Sheet.1!Prop.Cost)")
CASES += fn("TAN", "TAN(0)", "TAN(45 deg)")
CASES += fn("TEXTHEIGHT", "TEXTHEIGHT(Sheet.1!TheText)", "TEXTHEIGHT(Sheet.1!TheText,1 in)")
CASES += fn("TEXTWIDTH", "TEXTWIDTH(Sheet.1!TheText)", "TEXTWIDTH(Sheet.1!TheText,0.5 in)")
CASES += fn("THEMEGUARD", "THEMEGUARD(5)")
CASES += fn("THEMEPROP", "THEMEPROP(1)")
CASES += fn("THEMEVAL", "THEMEVAL()", "THEMEVAL(\"FillColor\")", "THEMEVAL(\"LineWeight\")")
CASES += fn("TODAY", "TODAY()-TODAY()")
CASES += fn("NOW", "NOW()-NOW()", "INT(NOW())-INT(TODAY())")
CASES += fn("TRIM", "TRIM(\"  a  b  \")", "TRIM(\"\")", "LEN(TRIM(\" x \"))")
CASES += fn("TRUNC", "TRUNC(2.789,2)", "TRUNC(-2.789,1)", "TRUNC(2.789)", "TRUNC(1234,-2)")
CASES += fn("UNICHAR", "UNICHAR(65)", "UNICHAR(8364)", "UNICHAR(128512)", "UNICHAR(0)")
CASES += fn("UPPER", "UPPER(\"hello\")", "UPPER(\"straße\")", "UPPER(5)")
CASES += fn("_ELLIPSE_THETA", "_ELLIPSE_THETA(0,1,0.5,0,0,1,0.5,1)")
# WP-15-T02: precedence, literals, units, references, coercion and errors.
CASES += fn("EXPR", "2+3*4", "(2+3)*4", "2^3^2", "-2^2", "10/4", "7-2-1", "1/0", "1+\"2\"", "\"a\"&\"b\"", "1=1", "1<>2", "\"a\"=\"A\"",
            "2 in+1 cm", "1 ft", "1 m", "90 deg", "1 rad", "3 pt", "2.5e2", "1+TRUE", "5 in*2", "5 in/2 in", "1 in+1", "1 in=72 pt",
            "\"a\"&1+2", "2*3^2", "-3^2+1", "\"b\">\"A\"", "\"abc\"<\"abd\"", "1&2", "2 in*3 in", "10 mm/2", "-(2 in)", "\"5\"*2", "\"x\"*2",
            "ATAN2(1,1)+1", "30 deg+1", "DATE(2026,1,1)-1", "DATE(2026,1,2)-DATE(2026,1,1)", "1+DATE(2026,1,1)", "ATAN2(1,1)+1 in",
            "BITAND(\"a\",1)", "BITAND(-1,0)", "BITOR(-1,0)", "SIGN(-2 in)", "SIGN(0 in)", "MODULUS(DATE(2026,1,1),7)", "DEG(ATAN2(1,1))",
            "ATAN2(\"1\",\"1\")", "ATAN2(TRUE,TRUE)", "RGB(0,0,255)", "BLUE(RGB(0,0,255))", "PAGENUMBER(0)", "PAGENUMBER(FALSE)")
CASES += fn("CELLREF", "Sheet.1!Width", "Sheet.1!PinX", "Sheet.1!User.Num*2", "Sheet.1!User.Len", "Sheet.1!User.Ang", "Sheet.1!Prop.Cost",
            "Sheet.1!Prop.Name", "Width", "User.Local+1", "ThePage!PageWidth", "Sheet.1!Angle", "Sheet.1!User.Missing", "Sheet.99!Width",
            "Sheet.1!LocPinX", "Sheet.1!TxtWidth", "Sheet.1!User.Str&\"d\"", "Sheet.1!User.Zero")
# WP-16-T03: every built-in field picture code and a spread of FORMAT pictures.
CASES += [(f"FIELDPICTURE-code-{n}", f"FIELDPICTURE({n})") for n in range(0, 256)]
FORMATS = ["0", "0.0", "#.##", "#,##0", "000.00", "0.00E+00", "# ?/?", "0 u", "0.00 u", "0.0 U", "0 \"in\"", "@", "@@", "\"x\"0", "0.0#", "#", "0;-0", "0;(0);\"zero\"",
           "yyyy-mm-dd", "dd/MM/yyyy", "MMMM d, yyyy", "ddd", "dddd", "h:mm", "HH:mm:ss", "h:mm AM/PM", "C", "D", "T", "{{dd MMM}}", "[h]:mm", "esc(20)", "esc(7)", "{<7>}"]
VALUES = {"num": "1234.5678", "neg": "-12.5", "len": "2.5 in", "mm": "25.4 mm", "ang": "45 deg", "date": "DATETIME(46320.75)", "dur": "1.5 ed", "str": "\"Text\""}
for vi, (vk, vf) in enumerate(VALUES.items()):
    for fi, picture in enumerate(FORMATS):
        CASES.append((f"FORMATX-{vk}-{fi}", f"FORMAT({vf},\"{picture.replace(chr(34), chr(34)*2)}\")"))
for vi, (vk, vf) in enumerate(VALUES.items()):
    for code in list(range(0, 41)) + [200, 201, 209, 215]:
        CASES.append((f"FORMATESC-{vk}-{code}", f"FORMAT({vf},\"esc({code})\")"))
SECTIONS = ["0;-0;\"zero\"", "#;#;\"z\"", "0.0;(0.0)", "\"p\"0;\"n\"0;\"z\"0", "0 u;-0 u", "#,##0.00", "0.000 u"]
for si, picture in enumerate(SECTIONS):
    for vk, vf in {"pos": "7.25", "neg": "-7.25", "zero": "0", "len": "-3 cm"}.items():
        CASES.append((f"FORMATSEC-{si}-{vk}", f"FORMAT({vf},\"{picture.replace(chr(34), chr(34)*2)}\")"))
# WP-16-T03: displayed text of inserted fields with Format cells.
FIELD_VALUES = {"num": "1234.5678", "len": "2.5 in", "mm": "25.4 mm", "ang": "45 deg", "date": "DATETIME(46320.75)", "str": "\"Text\"", "page": "PAGENAME()", "count": "PAGECOUNT()"}
FIELD_FORMATS = ["\"\"", "FIELDPICTURE(0)", "FIELDPICTURE(1)", "FIELDPICTURE(2)", "FIELDPICTURE(3)", "FIELDPICTURE(6)", "FIELDPICTURE(7)", "FIELDPICTURE(20)", "FIELDPICTURE(21)",
                 "FIELDPICTURE(24)", "FIELDPICTURE(31)", "FIELDPICTURE(37)", "FIELDPICTURE(38)", "FIELDPICTURE(39)", "FIELDPICTURE(201)", "FIELDPICTURE(215)", "\"0.00 u\"", "\"yyyy-MM-dd\"", "\"@\""]
FIELDS = [{"id": f"FIELD-{vk}-{fi}", "formula": vf, "format": ff} for vk, vf in FIELD_VALUES.items() for fi, ff in enumerate(FIELD_FORMATS)]
FIELDS += [{"id": f"FIELDCODE-{vk}-{n}", "formula": vf, "format": f"FIELDPICTURE({n})"} for vk, vf in {"date": "DATETIME(46320.75)", "num": "1234.5678"}.items() for n in list(range(19, 82)) + list(range(200, 222))]
FIELDS += [{"id": f"FIELDPIC-{vk}-{i}", "formula": vf, "format": "\"" + pic + "\""} for vk, vf in {"date": "DATETIME(46320.75)", "pm": "DATETIME(46320.25)"}.items()
           for i, pic in enumerate(["h:mm tt", "hh:mm:ss tt", "t", "tt", "AM/PM", "D", "C", "T", "ddddd", "dddddd", "yy", "y", "M", "d", "H", "s", "[m]", "[s]", "ww", "q", "dddd d MMMM"])]
# WP-17-T03: theme selectors on a drawing with no theme.
for sel in ["FillColor", "FillColor2", "LineColor", "ShadowColor", "FontColor", "LineWeight", "LineCap", "LinePattern", "FillPattern",
            "Font", "FontStyle", "ConnectorWeight", "Rounding", "ShadowPattern", "Background", "Accent1", "Accent6", "Dark", "Light"]:
    CASES.append((f"THEMEVALX-{sel}", f"THEMEVAL(\"{sel}\")"))
CASES += [(f"THEMEVALX-n{n}", f"THEMEVAL({n})") for n in range(0, 8)]
CASES += fn("THEMEVALX-default", "THEMEVAL(\"FillColor\",RGB(1,2,3))", "THEMEVAL(\"LineWeight\",2 pt)")
# WP-16-T04: Arial metrics, present on both platforms.
CASES += fn("ARIAL", "TEXTWIDTH(Sheet.3!TheText)", "TEXTHEIGHT(Sheet.3!TheText,1 in)", "TEXTHEIGHT(Sheet.3!TheText,4 in)", "TEXTWIDTH(Sheet.3!TheText,1 in)",
            "TEXTWIDTH(Sheet.4!TheText)", "TEXTHEIGHT(Sheet.4!TheText,4 in)", "SHAPETEXT(Sheet.4!TheText)", "LEN(SHAPETEXT(Sheet.4!TheText))")
# Remaining reference functions (inventory: recognized by Visio 2019, uncovered in MacVisio).
CASES += fn("DATETIME", "DATETIME(46320.75)", "DATETIME(\"25/10/2026 18:00\")", "DATETIME(\"2026-10-25\")", "DATETIME(0)", "DATETIME(-1)", "DATETIME(\"x\")")
CASES += fn("DATEVALUE", "DATEVALUE(\"25/10/2026\")", "DATEVALUE(\"25/10/2026 18:00\")", "DATEVALUE(46320.75)", "DATEVALUE(\"bad\")")
CASES += fn("TIMEVALUE", "TIMEVALUE(\"18:30\")", "TIMEVALUE(\"25/10/2026 18:30:15\")", "TIMEVALUE(46320.75)", "TIMEVALUE(\"bad\")")
CASES += fn("TIME", "TIME(18,30,15)", "TIME(25,0,0)", "TIME(0,90,0)", "TIME(-1,0,0)")
CASES += fn("YEAR", "YEAR(DATETIME(46320.75))", "YEAR(46320.75)", "YEAR(\"25/10/2026\")")
CASES += fn("MONTH", "MONTH(DATETIME(46320.75))", "MONTH(46320.75)")
CASES += fn("DAY", "DAY(DATETIME(46320.75))", "DAY(46320.75)")
CASES += fn("HOUR", "HOUR(DATETIME(46320.75))", "HOUR(46320.25)", "HOUR(TIME(18,30,15))")
CASES += fn("MINUTE", "MINUTE(TIME(18,30,15))", "MINUTE(46320.75)")
CASES += fn("SECOND", "SECOND(TIME(18,30,15))", "SECOND(46320.75)")
CASES += fn("WEEKDAY", "WEEKDAY(DATETIME(46320.75))", "WEEKDAY(46320.75)", "WEEKDAY(DATETIME(46321))")
CASES += fn("DAYOFYEAR", "DAYOFYEAR(DATETIME(46320.75))", "DAYOFYEAR(46023)")
CASES += fn("DOCPROPS", "TITLE()", "SUBJECT()", "CREATOR()", "MANAGER()", "COMPANY()", "CATEGORY()", "KEYWORDS()", "DESCRIPTION()", "FILENAME()",
            "LEN(DIRECTORY())>0", "DOCCREATION()-DOCLASTSAVE()<1", "DOCLASTEDIT()>0", "DOCLASTPRINT()", "HASCATEGORY(\"Probe\")", "HASCATEGORY(\"x\")")
CASES += fn("SHAPEINFO", "NAME()", "Sheet.1!NAME()", "NAME(0)", "NAME(1)", "MASTERNAME()", "MASTERNAME(1)", "TYPE()", "Sheet.1!TYPE()", "SHEETREF()", "LEN(SHEETREF())")
CASES += fn("MATHX", "BITNOT(5)", "BITNOT(-1)", "BITNOT(0)", "COSH(1)", "SINH(1)", "TANH(1)", "INTUP(2.1)", "INTUP(-2.1)", "INTUP(2)", "MAGNITUDE(3,4)",
            "MAGNITUDE(3 in,4 in)", "MAGNITUDE(1,1,1,1)", "RAND()<1", "RAND()>=0", "LOOKUP(\"b\",\"a;b;c\")", "LOOKUP(\"z\",\"a;b;c\")", "LOOKUP(\"b\",\"a|b\",\"|\")",
            "NA()", "ISERR(NA())", "ISERR(1/0)", "ISERR(1)", "ISERRNA(NA())", "ISERRNA(1/0)", "ISERROR(NA())", "ISERROR(1)", "ISERRVALUE(\"x\"*2)", "ISERRVALUE(1/0)",
            "CY(12.5,\"USD\")", "CY(12.5)", "FORMATEX(1234.5,\"0.00\",\"in\",\"mm\")", "FORMATEX(2 in,\"0.0 u\",\"in\",\"cm\")", "EVALTEXT(Sheet.1!TheText)",
            "FONTTOID(\"Arial\")", "FONTTOID(\"NoSuchFont\")", "DEPENDSON(Sheet.1!Width)", "USERUI(0,1,2)", "USERUI(1,1,2)", "GRAVITY(30 deg)", "GRAVITY(200 deg)",
            "GRAVITY(30 deg,10 deg,20 deg)")
CASES += fn("COLORX", "BLEND(RGB(255,0,0),RGB(0,0,255),0.5)", "BLEND(RGB(255,0,0),RGB(0,0,255),0)", "TINT(RGB(100,50,0),50)", "TONE(RGB(100,50,0),50)",
            "HUEDIFF(RGB(255,0,0),RGB(0,255,0))", "SATDIFF(RGB(255,0,0),RGB(128,128,128))", "CELLISTHEMED()", "THEME(\"Office\")", "THEMERESTORE()")
CASES += fn("GEOM", "PNT(1,2)", "PNTX(PNT(1,2))", "PNTY(PNT(1,2))", "PAR(PNT(1,2))", "Sheet.1!PAR(PNT(0.5,0.5))", "LOC(PNT(1,2))", "Sheet.1!LOC(PNT(2,1.5))",
            "LOCTOLOC(PNT(0,0),Sheet.1!Width,Sheet.2!Width)", "LOCTOPAR(PNT(0,0),Sheet.1!Width,ThePage!PageWidth)", "ANGLETOLOC(30 deg,Sheet.1!Width,Sheet.2!Width)",
            "ANGLETOPAR(30 deg,Sheet.1!Width,ThePage!PageWidth)", "PATHLENGTH(Sheet.1!Geometry1.Path)", "PATHLENGTH(Sheet.1!Geometry1.Path,1)",
            "SEGMENTCOUNT(Sheet.1!Geometry1.Path)", "PNTX(POINTALONGPATH(Sheet.1!Geometry1.Path,0.25))", "PNTY(POINTALONGPATH(Sheet.1!Geometry1.Path,0.25))",
            "PNTX(POINTALONGPATH(Sheet.1!Geometry1.Path,0.5,0.1))", "ANGLEALONGPATH(Sheet.1!Geometry1.Path,0.25)", "ANGLEALONGPATH(Sheet.1!Geometry1.Path,0.6)",
            "PNTX(NEARESTPOINTONPATH(Sheet.1!Geometry1.Path,2.5,0.2))", "PNTY(NEARESTPOINTONPATH(Sheet.1!Geometry1.Path,2.5,0.2))", "NEARESTPOINTONPATH(Sheet.1!Geometry1.Path,2.5,0.2)",
            "PATHSEGMENT(Sheet.1!Geometry1.Path,0.25)", "PATHSEGMENT(Sheet.1!Geometry1.Path,0.25,1)", "PNTX(BOUNDINGBOXRECT(0))", "BOUNDINGBOXRECT(0)",
            "BOUNDINGBOXDIST(0)", "BOUNDINGBOXDIST(1)", "BOUNDINGBOXDIST(2)", "BOUNDINGBOXDIST(3)",
            "INTERSECTX(0,0,45 deg,1,0,135 deg)", "INTERSECTY(0,0,45 deg,1,0,135 deg)", "INTERSECTX(0,0,0 deg,0,1,0 deg)", "RECTSECT(1,1,0,0,0)", "RECTSECT(1,2,3,4,1)", "RECTSECT(-1,0,1,1,0)")
CASES += fn("STRUCT", "CONTAINERCOUNT()", "CONTAINERMEMBERCOUNT()", "CONTAINERSHEETREF(1)", "LISTMEMBERCOUNT()", "LISTORDER()", "LISTSHEETREF()",
            "CALLOUTCOUNT()", "CALLOUTTARGETREF()", "Sheet.1!CONTAINERCOUNT()")
CASES += fn("ACTIONS", "CALLTHIS(\"x\")", "DEFAULTEVENT()", "GOTOPAGE(\"Second\")", "HELP(\"x\")", "OPENFILE(\"x\")", "OPENGROUPWIN()", "OPENPAGE(\"Second\")",
            "OPENSHEETWIN()", "PLAYSOUND(\"x\",0,0,0)", "QUEUEMARKEREVENT(\"x\")", "RUNADDON(\"x\")", "RUNADDONWARGS(\"x\",\"y\")", "RUNMACRO(\"x\")", "HYPERLINK(\"http://x\")")
CASES += [(f"METRIC-{i}", f"TEXTWIDTH(Sheet.{5 + i}!TheText)") for i in range(9)]
CASES += fn("COERCE", "RGB(TRUE,0,0)", "RGB(\"1\",0,0)", "RGB(1,2,3 pt)", "RGB(72 pt,0,0)", "BITAND(1 in,1)", "BITOR(TRUE,1)", "BITXOR(Sheet.1!User.Len,1)",
            "BITAND(65536,1)", "BITAND(1e308,1)", "SIGN(0.005 in,1 mm)", "SIGN(0.005 in,1 rad)", "ASIN(\"0.5\")", "ASIN(TRUE)", "ATAN2(1,1)/45 deg",
            "THEMEVAL(\"TextColor\",RGB(0,0,0))", "THEMEVAL(\"TextColor\")", "MIN(1 in,2)", "SUM(1 in,1 deg)", "MAX(1 deg,1)", "MODULUS(5 in,2 in)", "MODULUS(DATE(2026,1,1),2)",
            "DATE(2026,1,1)+0.5", "ROUND(2.5 in,0)", "INT(-2.5 in)", "ABS(-30 deg)", "SQRT(4 deg)", "CEILING(2.5 cm,1 cm)")
CASES += fn("ROUNDING", "CEILING(26 mm,1 mm)", "FLOOR(26.4 mm,1 mm)", "CEILING(2.5 cm,1)", "FLOOR(2.5 cm,1 cm)", "CEILING(26 mm,2 mm)", "CEILING(1 in,1 rad)",
            "CEILING(13 mm*2,1)", "CEILING(2.5 cm)", "FLOOR(2.5 cm)", "ROUND(25.46 mm,1)", "CEILING(1.2 ft,1 in)", "CEILING(30 deg,1 rad)", "CEILING(0.5,1 mm)", "FLOOR(-2.5 cm,1 cm)",
            "CEILING(Sheet.1!User.Len,1 mm)", "CEILING(Sheet.1!Width,1 cm)", "SIGN(0.005,1 mm)", "SIGN(0.05,1 mm)")
# Every catalogued function (WP-15-T03) also gets the same invalid vectors: no arguments, too many, a string,
# a length and an error argument. Action functions with side effects are not evaluated this way.
CATALOG_FUNCTIONS = ["ABS", "ACOS", "AND", "ANG360", "ASIN", "ATAN", "ATAN2", "BITAND", "BITOR", "BITXOR", "BKGPAGENAME", "BLUE", "BOUND",
    "CEILING", "CHAR", "CONCATENATE", "COS", "DATE", "DEG", "EXP", "FIELDPICTURE", "FIND", "FLOOR", "FORMAT", "GETREF", "GREEN", "GUARD", "HSL",
    "HUE", "ID", "IF", "IFERROR", "INDEX", "INT", "ISTHEMED", "LEFT", "LEN", "LN", "LOG10", "LOWER", "LUM", "LUMDIFF", "MAX", "MID", "MIN",
    "MODULUS", "NOT", "NOW", "NURBS", "OPENTEXTWIN", "OR", "PAGECOUNT", "PAGENAME", "PAGENUMBER", "PI", "POLYLINE", "POW", "RAD", "RED", "REF",
    "REPLACE", "REPT", "RGB", "RIGHT", "ROUND", "SAT", "SETATREF", "SETATREFEVAL", "SETATREFEXPR", "SETF", "SHAPETEXT", "SIGN", "SIN", "SQRT",
    "STRSAME", "STRSAMEEX", "SUBSTITUTE", "SUM", "TAN", "TEXTHEIGHT", "TEXTWIDTH", "THEMEGUARD", "THEMEPROP", "THEMEVAL", "TODAY", "TRIM",
    "TRUNC", "UNICHAR", "UPPER", "_ELLIPSE_THETA"]
ACTION_FUNCTIONS = {"SETF", "OPENTEXTWIN"}
for name in CATALOG_FUNCTIONS:
    if name in ACTION_FUNCTIONS: continue
    CASES += [(f"VEC-{name}-none", f"{name}()"), (f"VEC-{name}-many", f"{name}(1,1,1,1,1,1,1,1,1)"), (f"VEC-{name}-text", f"{name}(\"x\")"),
              (f"VEC-{name}-length", f"{name}(2 in)"), (f"VEC-{name}-error", f"{name}(1/0)")]

# String coercion of numbers, quantities, booleans, dates and colors; LN/LOG10 units; MIN/MAX with text.
CASES += fn("STRCOERCE", "UPPER(25.4 mm)", "UPPER(2.5 cm)", "UPPER(3 ft)", "UPPER(10 pt)", "UPPER(30 deg)", "UPPER(1.5 in)", "UPPER(1 m)", "UPPER(2 in+1 in)",
            "UPPER(1/3 in)", "UPPER(TRUE)", "UPPER(1/3)", "UPPER(DATE(2026,1,1))", "UPPER(RGB(1,2,3))", "UPPER(0.5 rad)", "UPPER(-2 in)", "UPPER(1000000 in)",
            "UPPER(0.000001 in)", "UPPER(Sheet.1!User.Len)", "UPPER(Sheet.1!User.Ang)", "UPPER(2 yd)", "UPPER(1 km)", "UPPER(1 mi)", "UPPER(3 ed)", "UPPER(2 eh)",
            "UPPER(12345.678 mm)", "SUBSTITUTE(25.4 mm,\"q\",\"q\")", "SUBSTITUTE(1 em,\"q\",\"q\")", "SUBSTITUTE(1 de,\"q\",\"q\")", "SUBSTITUTE(1 da,\"q\",\"q\")",
            "SUBSTITUTE(123456789012345678 in,\"q\",\"q\")", "SUBSTITUTE(0.1+0.2,\"q\",\"q\")", "LEN(25.4 mm)", "LEFT(2.5 cm,3)",
            "LN(25.4 mm)", "LOG10(100 mm)", "LN(30 deg)", "LOG10(2 cm)", "MAX(\"x\",5)", "MIN(\"x\",5)", "MAX(\"x\",-5)", "MAX(\"3\")")

# Host matrix: each function's first case evaluated through the cells that consume formulas in practice: a
# shape User cell, a page User cell, a Geometry row cell, a control handle cell and a text field. MacVisio
# evaluates these through its document calculation (--probe-hosts), not the direct evaluator.
HOSTS = ["shape", "page", "geometry", "control", "field"]
HOST_CASES = []
for name in CATALOG_FUNCTIONS:
    if name in ACTION_FUNCTIONS: continue
    first = next((f for i, f in CASES if i == f"{name}-1"), None)
    if first is None: continue
    HOST_CASES += [{"id": f"HOST-{name}-{host}", "function": name, "formula": first, "host": host} for host in HOSTS]

# Side effects last: SETF writes Sheet.2!User.Local in Visio.
CASES += fn("SETF", "SETF(GETREF(Sheet.2!User.Local),9)")

def main():
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("docs/evidence/reference/formulas/formula-cases.json")
    seen = set()
    for case_id, _ in CASES:
        assert case_id not in seen, case_id
        seen.add(case_id)
    spec = {"schemaVersion": 1, "document": {"Title": "Probe Title", "Subject": "Probe Subject", "Creator": "Probe Creator", "Manager": "Probe Manager",
            "Company": "Probe Company", "Category": "Probe", "Keywords": "alpha; beta", "Description": "Probe description"}, "page": {"name": "Probe Page", "width": "8.5 in", "height": "11 in", "extraPages": ["Second"]},
            "shapes": SHAPES, "host": "B", "cases": [{"id": i, "formula": f} for i, f in CASES], "fields": FIELDS,
            "hostShape": {"key": "E", "rect": [6, 3, 7, 4]}, "hostCases": HOST_CASES}
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(spec, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"{len(CASES)} cases -> {out}")

if __name__ == "__main__":
    main()
