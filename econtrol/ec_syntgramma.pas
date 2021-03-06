{ *************************************************************************** }
{                                                                             }
{ EControl Syntax Editor SDK                                                  }
{                                                                             }
{ Copyright (c) 2004 - 2015 EControl Ltd., Zaharov Michael                    }
{     www.econtrol.ru                                                         }
{     support@econtrol.ru                                                     }
{                                                                             }
{ *************************************************************************** }

{$mode delphi}

unit ec_SyntGramma;

interface

uses
  SysUtils,
  Classes,
  Dialogs,
  Contnrs,
  ec_StrUtils,
  ec_parser_rule,
  ec_token_holder,
  ATStringProc_TextBuffer;

type

  TParserNode = class
  protected
    function GetCount: integer; virtual; abstract;
    function GetNodes(Index: integer): TParserNode; virtual; abstract;
    function GetFirstToken: integer; virtual; abstract;
    function GetLastToken: integer; virtual; abstract;
  public
    property Count: integer read GetCount;
    property Nodes[Index: integer]: TParserNode read GetNodes; default;
    property FirstToken: integer read GetFirstToken;
    property LastToken: integer read GetLastToken;
  end;

  TParserBranchNode = class(TParserNode)
  private
    FNodes: TList;
    FRule: TParserRuleBranch;
  protected
    function GetCount: integer; override;
    function GetNodes(Index: integer): TParserNode; override;
    function GetFirstToken: integer; override;
    function GetLastToken: integer; override;
  public
    constructor Create(ARule: TParserRuleBranch);
    destructor Destroy; override;
    procedure Add(Node: TParserNode);
    property Rule: TParserRuleBranch read FRule;
  end;

  TParserTermNode = class(TParserNode)
  private
    FRule: TParserRuleItem;
    FTokenIndex: integer;
  protected
    function GetCount: integer; override;
    function GetNodes(Index: integer): TParserNode; override;
    function GetFirstToken: integer; override;
    function GetLastToken: integer; override;
  public
    constructor Create(ARule: TParserRuleItem; ATokenIndex: integer);
    property Rule: TParserRuleItem read FRule;
  end;





  { TGrammaAnalyzer }

  TGrammaAnalyzer = class(TPersistent)
  private
    FGrammaRules: TList;
    FGrammaDefs: TATStringBuffer;

    FRoot: TParserRule;
    FSkipRule: TParserRule;
    FOnChange: TNotifyEvent;
    FSyncWall:TRTLCriticalSection;
    function GetGrammaCount: integer;
    function GetGrammaRules(Index: integer): TParserRule;
    function GetGramma: ecString;
    procedure SetGramma(const Value: ecString);
  protected
    function GetGrammaLines: TATStringBuffer;
    procedure Changed; dynamic;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Assign(Source: TPersistent); override;
    procedure Clear;

    function ParserRuleByName(const AName: string): TParserRule;
    function IndexOfRule(Rule: TParserRule): integer;
    function CompileGramma(TokenNames: TStrings): Boolean;
    function  ParseRule(FromIndex: integer; Rule: TParserRule; Tags: TTokenHolder): TParserNode;
    function  ParseRuleFaster(const aFromIndex: integer; Rule: TParserRule; Tags: TTokenHolder):integer;
    function TestRule(FromIndex: integer; Rule: TParserRule; Tags: TTokenHolder): integer;

    property GrammaCount: integer read GetGrammaCount;
    property GrammaRules[Index : integer]: TParserRule read GetGrammaRules; default;
    property OnChange: TNotifyEvent read FOnChange write FOnChange;
  published
    property Gramma: ecString read GetGramma write SetGramma;
  end;


  TTraceParserProc = procedure(Sender: TObject; CurIdx: integer; const TraceStr: string) of object;
var
  TraceParserProc: TTraceParserProc;

implementation

uses
  ec_synt_collection,
  ec_rules,
  ec_SyntAnal, ec_SyntaxClient;


{ TParserNode }

procedure TParserBranchNode.Add(Node: TParserNode);
begin
  if FNodes = nil then FNodes := TObjectList.Create;
  FNodes.Add(Node);
end;

constructor TParserBranchNode.Create(ARule: TParserRuleBranch);
begin
  inherited Create;
  FRule := ARule;
end;

destructor TParserBranchNode.Destroy;
begin
  if FNodes <> nil then FNodes.Free;
  inherited;
end;

function TParserBranchNode.GetCount: integer;
begin
  if FNodes = nil then Result := 0
   else Result := FNodes.Count;
end;

function TParserBranchNode.GetFirstToken: integer;
begin
  if Count > 0 then
   Result := Nodes[Count - 1].FirstToken
  else
   Result := -1;
end;

function TParserBranchNode.GetLastToken: integer;
begin
  if Count > 0 then
   Result := Nodes[0].LastToken
  else
   Result := -1;
end;

function TParserBranchNode.GetNodes(Index: integer): TParserNode;
begin
  if FNodes <> nil then
    Result := TParserNode(FNodes[Index])
  else
   Result := nil;
end;

{ TParserTermNode }

constructor TParserTermNode.Create(ARule: TParserRuleItem;
  ATokenIndex: integer);
begin
  inherited Create;
  FRule := ARule;
  FTokenIndex := ATokenIndex;
end;

function TParserTermNode.GetCount: integer;
begin
  Result := 0;
end;

function TParserTermNode.GetFirstToken: integer;
begin
  Result := FTokenIndex;
end;

function TParserTermNode.GetLastToken: integer;
begin
  Result := FTokenIndex;
end;

function TParserTermNode.GetNodes(Index: integer): TParserNode;
begin
  Result := nil;
end;

{ TGrammaAnalyzer }

constructor TGrammaAnalyzer.Create;
begin
  inherited;
  FGrammaRules := TObjectList.Create;
  FGrammaDefs := TATStringBuffer.Create;
  InitCriticalSection(FSyncWall);
end;

destructor TGrammaAnalyzer.Destroy;
begin
  Clear;
  FGrammaDefs.Free;
  FGrammaRules.Free;
  DoneCriticalSection(FSyncWall);
  inherited;
end;

procedure TGrammaAnalyzer.Clear;
begin
  FGrammaRules.Clear;
  FGrammaDefs.Clear;
  FRoot := nil;
  FSkipRule := nil;
end;

procedure TGrammaAnalyzer.Assign(Source: TPersistent);
begin
  if Source is TGrammaAnalyzer then
   Gramma := (Source as TGrammaAnalyzer).Gramma;
end;

function TGrammaAnalyzer.ParserRuleByName(const AName: string): TParserRule;
var i : integer;
begin
  if AName <> '' then
   for i := 0 to FGrammaRules.Count - 1 do
    if SameText(AName, GrammaRules[i].Name) then
     begin
       Result := GrammaRules[i];
       Exit;
     end;
  Result := nil;
end;

function TGrammaAnalyzer.GetGrammaCount: integer;
begin
  Result := FGrammaRules.Count;
end;

function TGrammaAnalyzer.GetGrammaRules(Index: integer): TParserRule;
begin
  Result := TParserRule(FGrammaRules[Index]);
end;

function TGrammaAnalyzer.IndexOfRule(Rule: TParserRule): integer;
begin
  Result := FGrammaRules.IndexOf(Rule);
end;

function TGrammaAnalyzer.GetGramma: ecString;
begin
  Result := FGrammaDefs.FText;
end;

procedure TGrammaAnalyzer.SetGramma(const Value: ecString);
begin
  FGrammaDefs.SetupSlow(Value);
  Changed;
end;

function TGrammaAnalyzer.GetGrammaLines: TATStringBuffer;
begin
  Result := FGrammaDefs;
end;

// Compiling Gramma rules
function TGrammaAnalyzer.CompileGramma(TokenNames: TStrings): Boolean;
var Lex: TecSyntAnalyzer;
    Res: TecClientSyntAnalyzer;
    Cur, i: integer;
    Rule: TParserRule;

  procedure AddTokenRule(ATokenType: integer; Expr: string);
  var TokenRule: TecTokenRule;
  begin
    TokenRule := Lex.TokenRules.Add;
    TokenRule.TokenType := ATokenType;
    TokenRule.Expression := Expr;
  end;

  function ValidCur: Boolean;
  begin
    Result := Cur < Res.TagCount;
  end;

  procedure SkipComments;
  begin
    while ValidCur do
     if Res.Tags[Cur].TokenType = 0 then Inc(Cur)
      else Exit;
  end;

  procedure ReadRepeater(RuleItem: TParserRuleItem);
  var s: string;
  begin
    if not ValidCur then Exit;
    if Res.Tags[Cur].TokenType = 8 then
     begin
       s := Res.TagStr[Cur];
       if s = '+' then RuleItem._SetReptMax(-1) else
        if s = '?' then RuleItem._SetReptMin(0) else
         if s = '*' then
          begin
           RuleItem._SetReptMin(0);
           RuleItem._SetReptMax(-1);
          end;
       Inc(Cur);
     end;
  end;

  function ExtractRule: TParserRule; forward;

  function ExtractItem: TParserRuleItem;
  var t: TParserItemType;
      s: string;
      R: TParserRule;
  begin
    Result := nil;
    SkipComments;
    if not ValidCur then Exit;

    R := nil;
    case Res.Tags[Cur].TokenType of
      1: t := itTerminal;
      2: t := itTerminalNoCase;
      3: t := itTokenRule;
      4: t := itParserRule;
      9: begin // extract sub-rule
          t := itParserRule;
          R := ExtractRule;
          if not ValidCur or (R = nil) or
            (Res.Tags[Cur].TokenType <> 10) then Exit;
         end;
      else Exit;
    end;
    s := Res.TagStr[cur];
    if t <> itParserRule then
     begin
       if Length(s) <= 2 then Exit;
       Delete(s, Length(s), 1);
       Delete(s, 1, 1);
     end;
    Result := TParserRuleItem.Create;
    result._Setup(t, s, r, r<>nil);
    Inc(Cur);
    ReadRepeater(Result);
  end;

  function ExtractBranch: TParserRuleBranch;
  var Item, last: TParserRuleItem;
      apos, sv_pos: integer;
  begin
    Result := TParserRuleBranch.Create;
    last := nil;
    sv_pos := 0; // to avoid warning
    while ValidCur do
     begin
      apos := Cur;
      Item := ExtractItem;
      if Item <> nil then
       begin
        sv_pos := apos;
        Result.AddItem(Item);
        Item._SetBranch(Result);
        last := item
       end else
        if ValidCur then
         if (Res.Tags[Cur].TokenType = 7) or
            (Res.Tags[Cur].TokenType = 6) or
            (Res.Tags[Cur].TokenType = 10) then Exit
          else
           begin
            if (Res.Tags[Cur].TokenType = 5) and (last <> nil) and
               (last.ItemType = itParserRule) then
             begin
               Cur := sv_pos;
               Result.Delete(Result.Count- 1);
               Exit;
             end;
            Break;
           end;
     end;
    Result.Free;
    Result := nil;
  end;

  function ExtractRule: TParserRule;
  var Branch: TParserRuleBranch;
      s: string;
  begin
    Result := nil;
    SkipComments;
    S := '';
    if not ValidCur then Exit;
    case Res.Tags[Cur].TokenType of
      4: begin
          s := Res.TagStr[Cur];
          Inc(Cur);
          SkipComments;
          if not ValidCur or (Res.Tags[Cur].TokenType <> 5) then Exit;
          Inc(Cur);
         end;
      9: Inc(Cur);
      else Exit;
    end;

    Result := TParserRule.Create;
    Result._SetName(s);
    while ValidCur do
     begin
       Branch := ExtractBranch;
       if Branch = nil then Break;
       Result.AddBranch(Branch);
       Branch._SetRule(Result);
       if Res.Tags[Cur].TokenType = 6 then Inc(Cur) else
       if Res.Tags[Cur].TokenType = 7 then
        begin
         Inc(Cur);
         Exit;
        end else
       if Res.Tags[Cur].TokenType = 10 then Exit else
       if Result.Count > 0 then Exit else break;
     end;
    Result.Free;
    Result := nil;
  end;

  procedure LinkRuleItems(Rule: TParserRule);
  var j, k: integer;
      Item: TParserRuleItem;
  begin
    for j := 0 to Rule.Count - 1 do
     for k := 0 to Rule.Branches[j].Count - 1 do
       begin
         Item := Rule.Branches[j].Items[k];
         case Item.ItemType of
           itTokenRule: Item._SetTokenType( TokenNames.IndexOf(Item.Terminal) );
           itParserRule: if Item.IsSubRule then
                          LinkRuleItems(Item.ParserRule)
                         else
                          Item._SetRule(ParserRuleByName(Item.Terminal) );
         end;
       end;
  end;

begin
  Result := True;
  FGrammaRules.Clear;
  FRoot := nil;
  FSkipRule := nil;

  if GetGrammaLines.Count > 0 then
    begin
      Lex := TecSyntAnalyzer.Create(nil);
      try
        //Res := Lex.AddClient(nil, GetGrammaLines);
        Res := TecClientSyntAnalyzer.Create(Lex, GetGrammaLines, nil, nil, false);
        if Res <> nil then
        begin
          Res.WaitTillCoherent();
          try
            // Prepare Lexer
            AddTokenRule(0, '//.*');                 // comment
            AddTokenRule(0, '(?s)/\*.*?(\*/|\Z)');   // comment
            AddTokenRule(1, '".*?"');                // Terminal
            AddTokenRule(2, #39'.*?'#39);            // Terminal No case
            AddTokenRule(3, '<.*?>');                // Terminal -> Token rule
            AddTokenRule(4, '\w+');                  // Rule
            AddTokenRule(5, '=');                    // Equal
            AddTokenRule(6, '\|');                   // Or
            AddTokenRule(7, ';');                    // Rule stop
            AddTokenRule(8, '[\*\+\?]');             // Repeaters
            AddTokenRule(9, '[\(]');                 // Open sub-rule
            AddTokenRule(10,'[\)]');                 // Close sub-rule
            // Extract all tokens
            Res.Analyze;
            // extract rules
            Cur := 0;
            while ValidCur do
              begin
                Rule := ExtractRule;
                if Rule <> nil then
                  begin
                   Rule._SetIndex( FGrammaRules.Count);
                   FGrammaRules.Add(Rule);
                  end
                else Break;
              end;
            // performs linking
            for i := 0 to FGrammaRules.Count - 1 do
             LinkRuleItems(TParserRule(FGrammaRules[i]));
          finally
            Res.ReleaseBackgroundLock();
            Res.Free;
          end;
        end;
      finally
        Lex.Free;
      end;

      FRoot := ParserRuleByName('Root');
      FSkipRule := ParserRuleByName('Skip');
    end;
end;

function TGrammaAnalyzer.TestRule(FromIndex: integer; Rule: TParserRule; Tags: TTokenHolder): integer;
var FRootProgNode: TParserNode; // Results of Gramma analisys
begin
{$IF true}
Result:=ParseRuleFaster(FromIndex, Rule, Tags);

{$ELSE}
  FRootProgNode := ParseRule(FromIndex, Rule, Tags);
  if Assigned(FRootProgNode) then
    begin
      Result := FRootProgNode.FirstToken;
      FRootProgNode.Free;
    end else
      Result := -1;
{$ENDIF}
end;

function TGrammaAnalyzer.ParseRule(FromIndex: integer; Rule: TParserRule;
                        Tags: TTokenHolder): TParserNode;
var CurIdx: integer;
    CallStack: TList;
    In_SkipRule: Boolean;

  function RuleProcess(Rule: TParserRule): TParserNode; forward;

  procedure SipComments;
  var skipped: TParserNode;
  begin
    if not In_SkipRule and (FSkipRule <> nil) then
     try
       In_SkipRule := True;
       skipped := RuleProcess(FSkipRule);
       if skipped <> nil then skipped.Free;
     finally
       In_SkipRule := False;
     end;
  end;

  function ItemProcess(Item: TParserRuleItem): TParserNode;
  begin
    Result := nil;
    if CurIdx >= 0 then
     if Item.ItemType = itParserRule then
          Result := RuleProcess(Item.ParserRule)
      else
      begin
        case Item.ItemType of
          itTerminal:
            if Tags.GetTokenStr(CurIdx) = Item.Terminal then
              Result := TParserTermNode.Create(Item, CurIdx);
          itTerminalNoCase:
            if SameText(Tags.GetTokenStr(CurIdx), Item.Terminal) then
              Result := TParserTermNode.Create(Item, CurIdx);
          itTokenRule:
            if (Item.TokenType = 0) or (Tags.GetTokenType(CurIdx) = Item.TokenType) then
              Result := TParserTermNode.Create(Item, CurIdx);
        end;
        if Result <> nil then
         begin
          Dec(CurIdx);
          SipComments;
         end;
      end;
  end;

  function BranchProcess(Branch: TParserRuleBranch): TParserNode;
  var i, sv_idx, rep_cnt: integer;
      node: TParserNode;
  begin
    if Branch.Count = 0 then
     begin
      Result := nil;
      Exit;
     end;

    sv_idx := CurIdx;
    Result := TParserBranchNode.Create(Branch);
    for i := Branch.Count - 1 downto 0 do  begin
       rep_cnt := 0;
       node := nil;
       while ((rep_cnt = 0) or (node <> nil)) and
             ((Branch.Items[i].RepMax = -1) or (rep_cnt < Branch.Items[i].RepMax)) do
        begin
         node := ItemProcess(Branch.Items[i]);
         if node <> nil then TParserBranchNode(Result).Add(node) else
          if rep_cnt < Branch.Items[i].RepMin then
          begin
            CurIdx := sv_idx;
            Result.Free;
            Result := nil;
            Exit;
          end else Break;
         Inc(rep_cnt);
        end;
     end;
  end;

  function RuleProcess(Rule: TParserRule): TParserNode;
  var i, handle: integer;
  begin
    // Check stack
    handle := CurIdx shl 16 + Rule.Index;
    if CallStack.IndexOf(TObject(handle)) <> -1 then
       raise Exception.Create('Circular stack');
    CallStack.Add(TObject(handle));

    try
      Result := nil;
      for i := Rule.Count - 1 downto 0 do
       begin
  //       if Assigned(TraceParserProc) and not In_SkipRule then
  //           TraceParserProc(Self, CurIdx, ' ' + Rule.FName);
         Result := BranchProcess(Rule.Branches[i]);
         if Result <> nil then Exit;
       end;
    finally
      CallStack.Delete(CallStack.Count - 1);
    end;
  end;

begin
  CallStack := TList.Create;
  try
    CurIdx := FromIndex;
    Result := RuleProcess(Rule);
  finally
    CallStack.Free;
  end;
end;




function TGrammaAnalyzer.ParseRuleFaster(const aFromIndex: integer;
  Rule: TParserRule; Tags: TTokenHolder):integer;
const max=31;
var curIdx: integer;
    In_SkipRule: Boolean;
  pList:packed array[0..max] of LongWord;
   stackPtr:shortint;

  function ruleHash(r:TParserRule):LongWord;inline;
  begin
    result:=(r.Index shl 16) or (curIdx-aFromIndex+100)
  end;

  function CheckRecursive(r:TParserRule):boolean;
  var checkHash:LongWord;
      ruleIx:-1..max;
  begin
    checkHash:=ruleHash(r);
     for ruleIx:= stackPtr downto 0 do
      if  pList[ruleIx]=checkHash then exit(true);

     result:=false;
  end;

  procedure Push(r:TParserRule) ;inline;
  begin
    Inc(stackPtr);
    assert( (stackPtr<=max) and (r.Index<High(Word)) );
    pList[stackPtr] := ruleHash(r);
  end;


  procedure Pop;inline;
  begin
    Dec(stackPtr);
    Assert(stackPtr>=-1);
  end;

  function RuleProcess(Rule: TParserRule): integer; forward;

  procedure SipComments;
  var skipped: integer;
  begin
    if not In_SkipRule and (FSkipRule <> nil) then
     try
       In_SkipRule := True;
       skipped := RuleProcess(FSkipRule);
       //if skipped <> nil then skipped.Free;
     finally
       In_SkipRule := False;
     end;
  end;

  function ItemProcess(Item: TParserRuleItem): integer;
  begin
    Result := -1;
    if curIdx >= 0 then
     if Item.ItemType = itParserRule then begin
          Result := RuleProcess(Item.ParserRule);
          exit;
      end;

      case Item.ItemType of
        itTerminal:
          if Tags.GetTokenStr(curIdx) = Item.Terminal then
            Result := curIdx;// TParserTermNode.Create(Item, curIdx);
        itTerminalNoCase:
          if SameText(Tags.GetTokenStr(curIdx), Item.Terminal) then
            Result := curIdx; //TParserTermNode.Create(Item, curIdx);
        itTokenRule:
          if (Item.TokenType = 0) or (Tags.GetTokenType(curIdx) = Item.TokenType) then
            Result := curIdx;// TParserTermNode.Create(Item, curIdx);
      end;//case
      if Result >= 0 then begin
        Dec(curIdx);
        SipComments;
       end;
  end;

  function BranchProcess(Branch: TParserRuleBranch): integer;
  var branchIx, sv_idx, rep_cnt: integer;
      node, ruleCount: integer;
      curBranch:TParserRuleItem;

  begin
    ruleCount:=Branch.Count-1;
    if ruleCount < 0 then
             Exit(-1);
    sv_idx := curIdx;
    Result := -1;
    for branchIx := ruleCount  downto 0 do  begin
       rep_cnt := 0;
       node := -1;
       curBranch:=Branch.Items[branchIx];
       while ((rep_cnt = 0) or (node >= 0)) and
             ((curBranch.RepMax = -1) or (rep_cnt < curBranch.RepMax)) do
        begin
         node := ItemProcess(curBranch);
         if node >=0  then Result:=node
         else if rep_cnt < curBranch.RepMin then begin
            curIdx := sv_idx;
            Exit(-1);
         end
         else Break;
         Inc(rep_cnt);
        end;
     end;
  end;

  function RuleProcess(Rule: TParserRule): integer;
  var ruleIx, handle, ruleCount: integer;
      ruleBranch:TParserRuleBranch;
      rmIx:integer;
  begin
    // Check stack
    //handle := curIdx shl 16 + Rule.Index;
    if CheckRecursive(rule) then// ; FCallStack.IndexOf(TObject(handle)) <> -1 then
       raise Exception.Create('Circular stack');
    Push(rule);
    //FCallStack.Add(TObject(handle));

    try
      Result := -1;
      ruleCount:= Rule.Count - 1;
      for ruleIx := ruleCount downto 0 do begin
       ruleBranch:=Rule.Branches[ruleIx];
  //       if Assigned(TraceParserProc) and not In_SkipRule then
  //           TraceParserProc(Self, curIdx, ' ' + Rule.FName);
         Result := BranchProcess(ruleBranch);
         if Result >=0 then break;
       end;
    finally
      Pop();
      //FCallStack.Delete(FCallStack.Count - 1);
    end;
  end;

begin
  stackPtr:=-1;
  EnterCriticalSection(FSyncWall);
  try
    curIdx := aFromIndex;
    Result := RuleProcess(Rule);
  finally
    LeaveCriticalSection(FSyncWall);
  end;
end;

procedure TGrammaAnalyzer.Changed;
begin
  if Assigned(FOnChange) then FOnChange(Self);
end;

initialization
  TraceParserProc := nil;

finalization

end.
