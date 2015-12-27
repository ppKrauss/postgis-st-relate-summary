-- -- -- 
-- -- -- 
-- Functions for translate, explain or summarize the ouput of ST_Relate().
-- Tested with PostGIS 1.5+ and PostgreSQL 9.X
-- (C)PPKrauss 2012 - https://github.com/ppKrauss/postgis-st-relate-summary
--             (original old http://code.google.com/p/postgis-st-relate-summary/ )
-- Main functions:
--    lib.ST_Relate_summary(varchar [,varchar,varchar])
--    lib.ST_Relate_summaryMatch(varchar,varchar [,varchar])
-- Other useful functions:
--    lib.ST_Relate_summary(varchar [, boolean, ....])
--    lib.ST_Relate_summaryMatch_exact(VARCHAR, VARCHAR [, ...])
--

CREATE SCHEMA IF NOT EXISTS lib; -- PostgreSQL 9.3

CREATE OR REPLACE FUNCTION lib.ST_Relate_summary(
 -- 
 -- Summarize DE-9IM string code, translating it into human-readable or compact descriptor.
 -- For summarize more, use p_usesufix=false and p_symmetrize=true.
 -- Can be used also as "explainer function" (use p_explain=true)
 -- Version 1.0 of 2012-05
 -- See sources at http://en.wikipedia.org/wiki/DE-9IM 
 -- See motivations at http://gis.stackexchange.com/q/26124/7505
 -- Examples (using returned codes of ST_Relate(a,b)):
 --   SELECT lib.st_relate_summary('FF2F01212');
 --   SELECT lib.st_relate_summary('212101212',true,true,true,true,NULL,' | ');
 --   SELECT lib.st_relate_summary('212101212',true,NULL);
 --   SELECT lib.st_relate_summary('FF2F01212',false,false);
 -- A special string with dims, ST_Dimension(a)||ST_Dimension(b), can be used for Crosses and Overlaps:
 --   SELECT lib.st_relate_summary('0F1FF0102');      -- no check about Crosses predicate (it need p_dims).  
 --   SELECT lib.st_relate_summary('110F1FF0102');    -- adding dimensions at the first two positions (11=line/line).
 --   SELECT lib.st_relate_summary('11-0F1FF0102');   -- same, and using hiphen.  
 --   SELECT lib.st_relate_summary('220F1FF0102');    -- change interpretation to Overlaps (22=area/area).
 --   SELECT lib.st_relate_summary('0F1FF0102',true,false,false,false,false,NULL,'11');  -- using the p_dims parameter.
 -- 
  p_de9im VARCHAR,                    -- DE-9IM string code (returned by st_relate function).
  p_usesufix BOOLEAN DEFAULT TRUE,    -- use sufix flag. Sufix for more summarization.
  p_use3let BOOLEAN DEFAULT FALSE,    -- true= use 3letters-code flag, false=descriptor, NULL=both. 
  p_symmetrize BOOLEAN DEFAULT FALSE, -- true= turns assymetric pairs of predicates into one: Covers=CoveredBy, Within=Contains. 
  p_ignore BOOLEAN DEFAULT FALSE,     -- true= simplify ignoring Within and Contains, because they are in CoveredBy and Covers. 
  p_explain BOOLEAN DEFAULT FALSE,    -- true= "explain mode", false="summarize mode", NULL "explain mode at left". 
  p_sep VARCHAR DEFAULT ' - ',        -- separator
  p_dims VARCHAR DEFAULT ''           -- optional for input dimensions string.
) RETURNS VARCHAR AS $f$
DECLARE
    cases text[];
    p_de9im_complete varchar;
    aux varchar;
    sufix VARCHAR[];
    labelidx INTEGER;
    r VARCHAR;
    i INTEGER;
    typeidx INTEGER;
    label text;
    label_check boolean;
    ret text[];
    rec BOOLEAN := false;
BEGIN
    IF char_length(p_de9im)>=11 OR p_dims>'' THEN 
        p_de9im := translate(p_de9im,'-','');
	p_de9im_complete := COALESCE(p_dims,'')||p_de9im;
	IF char_length(p_de9im)=11 THEN 
	        p_de9im := substring(p_de9im from 3);
	END IF;
    END IF;
    IF p_de9im IS NULL THEN
       RETURN E'SYNOPSIS:\n lib.ST_Relate_summary(de9im,[usesufix=t/f, use3let=f/t/null, symmetrize=t/f, ignore=t/f, explain=t/f, sep])\n';
    ELSEIF char_length(p_de9im)!=9 OR translate(p_de9im,'012F','')!='' THEN 
       RETURN 'código DE-9IM invalido, '|| p_de9im;
    END IF;
    IF p_use3let IS NULL THEN p_use3let:=true; rec:=true; END IF;
	-- FALTA conferir quais os digitos representatios da dimensao do predicado 
    cases := ARRAY[ -- 10 Spatial Predicates's (abbreviation, name, regular expression), 9 digit codes 
      ARRAY['eql', 'Equals',     '^([012]).F..FFF'],      -- idx 1
      ARRAY['dsj', 'Disjoint',   '^FF.FF'],               -- idx 2
      ARRAY['int', 'Intersects', '^(?:(?:([012])....)|(?:.([012])...)|(?:...([012]).)|(?:....([012])))'],  -- idx 3
      ARRAY['tch', 'Touches',    '^(?:(?:F([012])...)|(?:F..([012]).)|(?:F...([012])))'],                  -- idx 4
      ARRAY['crs', 'Crosses',    '^(?:(?:(?:01|02|12)([012]).[012]....)|(?:(?:10|12|21)([012]).....[012])|(?:11(0)......))'], -- idx 5, 11 digits
      ARRAY['wth', 'Within',     '^([012]).F..F'],        -- idx 6
      ARRAY['cnt', 'Contains',   '^([012]).....FF'],      -- idx 7
      ARRAY['ovr', 'Overlaps',   '^(?:(?:(?:00|22)([012]).([012])...([012]))|(?:11(1).[012]...[012]))'], -- idx 8, 11-digits 
      ARRAY['cvr', 'Covers',     '^(?:(?:([012]).....FF)|(?:.([012])....FF)|(?:...([012])..FF)|(?:....([012]).FF))'],
      ARRAY['cvb', 'CoveredBy',  '^(?:(?:([012]).F..F)|(?:.([012])F..F)|(?:..F([012]).F)|(?:..F.([012])F))']  -- idx 10
    ];
    sufix :=  CASE WHEN p_use3let THEN ARRAY['2','1','0',''] ELSE ARRAY['-area','-line','-point',''] END;
    labelidx = CASE WHEN p_use3let THEN 1 ELSE 2 END; 
    FOR i IN 1..10 LOOP
      IF NOT(p_ignore AND (i=6 OR i=7)) THEN  -- simplify ignoring Within and Contains
       aux := CASE WHEN i=5 OR i=8 THEN p_de9im_complete ELSE p_de9im END;
       r := array_to_string(regexp_matches(aux,cases[i][3]),'');
       IF r >'' THEN
        typeidx := CASE WHEN cases[i][1]='dsj' THEN 4     -- no sufix
                WHEN strpos(r,'2')::BOOLEAN THEN 1        -- area
                WHEN strpos(r,'1')::BOOLEAN THEN 2        -- line 
                ELSE 3                                    -- point 
        END;
        IF p_symmetrize THEN -- change labels, Covers to CoveredBy, and Within to Contains 
		label_check:=false;
                IF i=9 THEN i:=10; label_check:=true; 
		ELSEIF i=6 THEN i:=7; label_check:=true; END IF;
        END IF;
        label := CASE WHEN p_usesufix THEN (cases[i][labelidx] || sufix[typeidx]) ELSE cases[i][labelidx] END;
	IF NOT(p_symmetrize) OR NOT(  label_check AND ret::varchar LIKE ('%'||label::varchar||'%')  ) THEN
	        ret := ret || array[label]; -- do always, except on checkeds (to not repeat same label).
	END IF;
        EXIT WHEN i=1;  -- cases[i][1]='eql';
       END IF; -- r
      END IF; -- ignore
    END LOOP;
    RETURN CASE WHEN p_explain=true THEN p_de9im ||p_sep ELSE '' END
           || array_to_string( ret , CASE WHEN p_use3let THEN ' ' ELSE ' & ' END )
           || CASE WHEN rec THEN ' ('|| lib.ST_Relate_summary(p_de9im, p_usesufix, false)||')' ELSE '' END
           || CASE WHEN p_explain IS NULL THEN p_sep || p_de9im ELSE '' END;
END; $f$ LANGUAGE plpgsql;


-- DROP FUNCTION lib.ST_Relate_summary(VARCHAR,VARCHAR,VARCHAR);  -- drops v1.2
CREATE OR REPLACE FUNCTION lib.ST_Relate_summary(
 -- 
 -- Summarize DE-9IM string code, translating it into human-readable or compact descriptor.
 -- Alias for ST_Relate_summary(varchar,boolean,*), setting parameters by string options.
 -- Version 1.0 of 2012-05.
 -- Examples:
 --   SELECT lib.st_relate_summary('0FFFFF0F2','easy');
 --   SELECT lib.st_relate_summary('212101212','','|');
 --   SELECT lib.st_relate_summary('110FFFFF0F2');
 --
    p_de9im VARCHAR,     -- DE-9IM string code (returned by st_relate function).
    p_opt   VARCHAR,  -- setting options:
          -- s=use sufix;  a=abbreviated descriptor, b=both descriptors;
          -- y=symmetrize Covers and Within;  i=ignore Within and Contains; 
          -- e=explain right; l=explain left.
          -- [012][012] = input dimensions (optional ... FALTA IMPLEMENTAR) 
    p_sep VARCHAR DEFAULT ' - ',   -- separator
    p_dims VARCHAR DEFAULT ''      -- optional for input dimensions string.
) RETURNS VARCHAR AS $f$
  SELECT CASE 
	WHEN translate($2,'012abeilsy','')>'' THEN
            'ERROR, check ST_Relate_summary() valid options' 
         ELSE lib.ST_Relate_summary(
            $1,    -- p_de9im
            CASE WHEN strpos($2, 's')::BOOLEAN THEN true ELSE false END,
            CASE WHEN strpos($2, 'a')::BOOLEAN THEN true WHEN strpos($2, 'b')::BOOLEAN THEN NULL ELSE false END,
            CASE WHEN strpos($2, 'y')::BOOLEAN THEN true ELSE false END,
            CASE WHEN strpos($2, 'i')::BOOLEAN THEN true ELSE false END,
            CASE WHEN strpos($2, 'e')::BOOLEAN THEN true WHEN strpos($2, 'l')::BOOLEAN THEN NULL ELSE false END,
            $3,   -- p_sep
	    translate($4,'abeilsy','')    -- p_dims
           ) 
         END;
$f$ LANGUAGE sql;
 
 
CREATE OR REPLACE FUNCTION lib.ST_Relate_summaryMatch_exact(
    p_de9im VARCHAR,  -- source
    p_checklist VARCHAR,    -- compares with 
    p_usesufix BOOLEAN DEFAULT TRUE,    -- same default 
    p_symmetrize BOOLEAN DEFAULT FALSE, -- same default. 
    p_ignore BOOLEAN DEFAULT FALSE     -- same default.
) RETURNS BOOLEAN AS $f$
 -- 
 -- Checks by ST_Relate_summary() if DE-9IM code satisfy a exact list of predicates.
 --
  SELECT CASE WHEN lib.ST_Relate_summary($1,$3,true,$4,$5)=lower($2) THEN true ELSE false END;
$f$ LANGUAGE sql;
 
CREATE OR REPLACE FUNCTION lib.ST_Relate_summaryMatch_exact(
    p_de9im VARCHAR,        -- source
    p_checklist VARCHAR,    -- list of 3-letter abbreviated names of predicates 
    p_options VARCHAR -- see lib.ST_Relate_summary(varchar,varchar,*) options.
) RETURNS BOOLEAN AS $f$
 -- 
 -- Checks by ST_Relate_summary() if DE-9IM code satisfy a exact list of predicates.
 --
  SELECT CASE WHEN lib.ST_Relate_summary($1, translate($3,'ae','')||'a')=lower($2) THEN true ELSE false END;
$f$ LANGUAGE sql;
 
 
CREATE OR REPLACE FUNCTION lib.ST_Relate_summaryMatch(
  p_de9im VARCHAR,             -- DE-9IM string code (returned by st_relate function).
  p_checklist VARCHAR,         -- list of 3-letter abbreviated names of predicates.
  p_options varchar DEFAULT '='  -- mode of matching,
     -- '>'	result list contains the checklist.
     -- '<'	result list is within the checklist.
     -- '='     equal. Both, '>' and '<'. 
     -- '&'     result list and checklist Overlaps (have elements in common).
  -- for other options, see ST_Relate_summary(varchar,varchar,*) 
) RETURNS BOOLEAN AS $f$
 -- 
 -- Checks by ST_Relate_summary() if DE-9IM code satisfy a list of predicates.
 -- The predicates must in the summarized 3-letter format.
 --
 -- Examples:
 --   SELECT lib.st_relate_summaryMatch('FF2F01212','int0 tch0');      -- true
 --   SELECT lib.st_relate_summaryMatch('FF2F01212','FF2F01212 1F2F01F1F');  -- true
 --   SELECT lib.st_relate_summaryMatch('FF2F01212','int tch','=iy');  -- true
 --   SELECT lib.st_relate_summaryMatch('FF2F01212','int1 tch0');      -- false
 --   SELECT lib.st_relate_summaryMatch('FF2F01212','int');            -- false
 --   SELECT lib.st_relate_summaryMatch('FF2F01212','int','=');        -- false
 --   SELECT lib.st_relate_summaryMatch('FF2F01212','int','>');        -- true
 --   SELECT lib.st_relate_summaryMatch('FF2F01212','int','&');        -- true
 --   SELECT lib.st_relate_summaryMatch('FF2F01212','int','<');        -- false
 --   SELECT lib.st_relate_summaryMatch('212101212','int2 crs2 ovr2'); -- true
 --   SELECT lib.st_relate_summaryMatch('212111212','int2 crs2 ovr2'); -- true
 --
DECLARE
	p_mode varchar;
	sufix varchar;
	checklist varchar[];
	thelist varchar[];
	contains  BOOLEAN := false;
	contained BOOLEAN := false;
	ret BOOLEAN;
BEGIN
	p_mode := translate(p_options,'abeilsy',''); -- isolating mode string
        IF translate(p_mode,'=><&','')>'' OR p_mode='' THEN p_mode:='='; END IF; -- set to default
	p_options := translate(p_options,'=><&',''); -- drops mode from option.
	sufix  := CASE WHEN translate(p_checklist, '012', '')=p_checklist THEN '' ELSE 's' END; -- autodetect
	checklist := string_to_array( lower(trim(p_checklist)), ' ' );
	IF char_length(checklist[1])=9 THEN -- a uniform list of codes
		thelist := ARRAY[lower(p_de9im)]::varchar[];
		IF p_mode='=' THEN p_mode:='&'; END IF;
	ELSE  -- a list of predicates
		thelist   := string_to_array( lower(lib.ST_Relate_summary(p_de9im, translate(p_options,'aes','')||'a'||sufix)), ' ' );
	END IF;
	IF p_mode='>' OR p_mode='=' THEN 
		contains := thelist @> checklist;
	END IF;
	IF p_mode='<' OR p_mode='=' THEN 
		contained := thelist <@ checklist;
	END IF;
	RETURN CASE 	WHEN p_mode='>' THEN contains 
			WHEN p_mode='<' THEN contained         
			WHEN p_mode='=' THEN (contains AND contained) -- equal lists
			WHEN p_mode='&' THEN (thelist && checklist)   -- lists overlaps
			ELSE NULL
		END;
END;
$f$ LANGUAGE plpgsql;

