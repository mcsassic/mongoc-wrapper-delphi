unit MongoBsonSerializer;

interface

{$i DelphiVersion_defines.inc}

uses
  Classes, SysUtils, TypInfo,
  MongoBson,
  {$IFDEF DELPHIXE}System.Generics.Collections,{$ENDIF}
  uCnvDictionary;

const
  SERIALIZED_ATTRIBUTE_ACTUALTYPE = '_type';
  SERIALIZED_ATTRIBUTE_COLLECTION_KEY = '_key';
  SERIALIZED_ATTRIBUTE_COLLECTION_VALUE = '_value';

type
  TObjectAsStringList = class(TStringList);

  // Dictionaries with string key can be serialized as bson object(Simple mode) where field name is Dictionary key
  // such bson have simpler structure and it's more clear to understand
  // however mongodb doesn't allow field names that contains . or starts with $
  // use ForceComplex mode to avoid this issue(Dictionaries with string key will be also serialized in Complex mode)
  // Dictionaries with non-string key serialized as array ob objects with key/value subobjects(Complex mode)
  TDictionarySerializationMode = (
    Simple,
    ForceComplex
  );

  TObjectBuilderFunction = function(const AClassName : string; AContext : Pointer) : TObject;

  EDynArrayUnsupported = class(Exception)
    constructor Create;
  end;

  EBsonSerializationException = class(Exception);

  EBsonSerializer = class(Exception);
  TBaseBsonSerializerClass = class of TBaseBsonSerializer;
  TBaseBsonSerializer = class
  private
    FTarget: IBsonBuffer;
  protected
    procedure Serialize_type(ASource: TObject);
  public
    constructor Create; virtual;
    procedure Serialize(const AName: String; ASource: TObject); virtual; abstract;
    property Target: IBsonBuffer read FTarget write FTarget;
  end;

  EBsonDeserializer = class(Exception);
  TBaseBsonDeserializerClass = class of TBaseBsonDeserializer;
  TBaseBsonDeserializer = class
  private
    FSource: IBsonIterator;
  public
    constructor Create; virtual;
    procedure Deserialize(var ATarget: TObject; AContext: Pointer); virtual; abstract;
    property Source: IBsonIterator read FSource write FSource;
  end;

  TPrimitivesBsonSerializer = class(TBaseBsonSerializer)
  private
    procedure SerializeObject(APropInfo: PPropInfo; ASource: TObject);
    procedure SerializePropInfo(APropInfo: PPropInfo; ASource: TObject);
    procedure SerializeSet(APropInfo: PPropInfo; ASource: TObject);
    procedure SerializeVariant(APropInfo: PPropInfo; const AName: String; const AVariant: Variant; ASource: TObject);
    {$IFDEF DELPHI2007}
    procedure SerializeDynamicArrayOfObjects(APropInfo: PPropInfo; ASource: TObject);
    {$ENDIF}
  public
    procedure Serialize(const AName: String; ASource: TObject); override;
  end;

  TPrimitivesBsonDeserializer = class(TBaseBsonDeserializer)
  private
    class function BuildObject(const _Type: string; AContext : Pointer): TObject;
    procedure DeserializeIterator(var ATarget: TObject; AContext : Pointer);
    procedure DeserializeObject(p: PPropInfo; ATarget: TObject; AContext: Pointer); overload;
    procedure DeserializeObject(AObjClass: TClass; var AObj: TObject;
                                ASource: IBsonIterator; AContext: Pointer); overload;
    procedure DeserializeSet(p: PPropInfo; var ATarget: TObject);
    procedure DeserializeVariantArray(p: PPropInfo; var v: Variant);
    {$IFDEF DELPHI2007}
    procedure DeserializeDynamicArrayOfObjects(p: PPropInfo; var ATarget: TObject; AContext : Pointer);
    {$ENDIF}
    function GetArrayDimension(it: IBsonIterator) : Integer;
  public
    procedure Deserialize(var ATarget: TObject; AContext : Pointer); override;
  end;

{ ****** IMPORTANT *******
  The following registration functions are NOT threadsafe with their corresponding lookup functions
  They are meant to be used during application initialization only. Don't attempt to register new serializers or buildable
  serializable classes during normal course of execution. If you do so, you will get nasty errors due to concurrent access
  to the structures holding objects registered by the following routines }
procedure RegisterClassSerializer(AClass : TClass; ASerializer : TBaseBsonSerializerClass);
procedure UnRegisterClassSerializer(AClass: TClass; ASerializer : TBaseBsonSerializerClass);
function CreateSerializer(AClass : TClass): TBaseBsonSerializer;

procedure RegisterClassDeserializer(AClass: TClass; ADeserializer: TBaseBsonDeserializerClass);
procedure UnRegisterClassDeserializer(AClass: TClass; ADeserializer: TBaseBsonDeserializerClass);
function CreateDeserializer(AClass : TClass): TBaseBsonDeserializer;

procedure RegisterBuildableSerializableClass(const AClassName : string; ABuilderFunction : TObjectBuilderFunction);
procedure UnregisterBuildableSerializableClass(const AClassName : string);

{ Use Strip_T_FormClassName() when comparing a regular Delphi ClassName with a serialized _type attribute
  coming from service-bus passed as parameter to object builder function }
function Strip_T_FormClassName(const AClassName : string): string;

var
  DictionarySerializationMode: TDictionarySerializationMode;

implementation

uses
  SyncObjs, uLinkedListDefaultImplementor, uScope
  {$IFNDEF VER130}, Variants{$ELSE}{$IFDEF Enterprise}, Variants{$ENDIF}{$ENDIF},
  uDelphi5;

const
  SBoolean = 'Boolean';
  STrue = 'True';
  STDateTime = 'TDateTime';
  SFalse = 'False';

resourcestring
  SSuitableBuilderNotFoundForClass = 'Suitable builder not found for class <%s>';
  SCanTBuildPropInfoListOfANilObjec = 'Can''t build PropInfo list of a nil object';
  SObjectHasNotPublishedProperties = 'Object has not published properties. review your logic';
  SFailedObtainingTypeDataOfObject = 'Failed obtaining TypeData of object %s';
  SCouldNotFindClass = 'Could not find target for class %s';

type
  TObjectDynArray = array of TObject;
  {$IFDEF DELPHIXE}
  TClassPairList = TList<TPair<TClass, TClass>>;
  TClassPair = TPair<TClass, TClass>;
  {$ELSE}
  TClassPair = class
  private
    FKey : TClass;
    FValue: TClass;
  public
    constructor Create(AKey : TClass; AValue : TClass);
    property Key : TClass read FKey;
    property Value: TClass read FValue;
  end;

  TClassPairList = class(TList)
  private
    function GetItem(Index : integer) : TClassPair;
  public
    property Items[Index : integer] : TClassPair read GetItem; default;
  end;
  {$ENDIF}

  TDefaultObjectBsonSerializer = class(TBaseBsonSerializer)
  public
    procedure Serialize(const AName: String; ASource: TObject); override;
  end;

  TStringsBsonSerializer = class(TBaseBsonSerializer)
  public
    procedure Serialize(const AName: String; ASource: TObject); override;
  end;

  TStreamBsonSerializer = class(TBaseBsonSerializer)
  public
    procedure Serialize(const AName: String; ASource: TObject); override;
  end;

  TStringsBsonDeserializer = class(TBaseBsonDeserializer)
  public
    procedure Deserialize(var ATarget: TObject; AContext : Pointer); override;
  end;

  TStreamBsonDeserializer = class(TBaseBsonDeserializer)
  public
    procedure Deserialize(var ATarget: TObject; AContext : Pointer); override;
  end;

  TObjectAsStringListBsonSerializer = class(TBaseBsonSerializer)
  public
    procedure Serialize(const AName: String; ASource: TObject); override;
  end;

  TObjectAsStringListBsonDeserializer = class(TBaseBsonDeserializer)
  public
    procedure Deserialize(var ATarget: TObject; AContext: Pointer); override;
  end;

  TCnvStringDictionarySerializer = class(TBaseBsonSerializer)
    procedure SerializeKeyValuePairSimple(const AKey: string; const AValue: TObject; AUserData: Pointer);
    procedure SerializeKeyValuePairComplex(const AKey: string; const AValue: TObject; AUserData: Pointer);
    procedure SerializeValue(const AKey: string; const AValue: TObject);
  public
    procedure Serialize(const AName: String; ASource: TObject); override;
  end;

  TCnvStringDictionaryDeserializer = class(TBaseBsonDeserializer)
  private
    class procedure DeserializeValue(var ADic: TCnvStringDictionary; AContext: Pointer;
      it: IBsonIterator; const AKey: string);
    procedure SimpleDeserialize(var ADic: TCnvStringDictionary; AContext : Pointer);
    procedure ComplexDeserialize(var ADic: TCnvStringDictionary; AContext : Pointer);
  public
    procedure Deserialize(var ATarget: TObject; AContext : Pointer); override;
  end;

var
  Serializers : TClassPairList;
  Deserializers : TClassPairList;
  BuilderFunctions : TCnvStringDictionary;
  PropInfosDictionaryCacheTrackingListLock : TSynchroObject;
  PropInfosDictionaryCacheTrackingList : TList;

threadvar
  // To reduce contention maintaining cache of PropInfosDictionary we will keep one cache per thread using a threadvar (TLS)
  PropInfosDictionaryDictionary : TCnvIntegerDictionary;

constructor EDynArrayUnsupported.Create;
begin
  inherited Create('tkDynArray Unsupported in this Delphi version');
end;

function Strip_T_FormClassName(const AClassName : string): string;
begin
  Result := AClassName;
  if (Result <> '') and (UpCase(Result[1]) = 'T') then
    system.Delete(Result, 1, 1);
end;

function GetPropInfosDictionaryDictionary : TCnvIntegerDictionary;
begin
  if PropInfosDictionaryDictionary = nil then
    begin
      PropInfosDictionaryDictionary := TCnvIntegerDictionary.Create(true);
      try
        PropInfosDictionaryCacheTrackingListLock.Acquire;
        try
          PropInfosDictionaryCacheTrackingList.Add(PropInfosDictionaryDictionary);
        finally
          PropInfosDictionaryCacheTrackingListLock.Release;
        end;
      except
        PropInfosDictionaryDictionary.Free;
        PropInfosDictionaryDictionary := nil;
        raise;
      end;
    end;
  Result := PropInfosDictionaryDictionary;
end;

function GetSerializableObjectBuilderFunction(const AClassName : string):
    TObjectBuilderFunction;
var
  stub: TObject;
begin
  Result := nil;
  if BuilderFunctions.TryGetValue(AClassName, stub) then
    Result := TObjectBuilderFunction(stub);
end;

{$IFNDEF DELPHIXE}
constructor TClassPair.Create(AKey : TClass; AValue : TClass);
begin
  inherited Create;
  FKey := AKey;
  FValue := AValue;
end;

function TClassPairList.GetItem(Index : integer) : TClassPair;
begin
  Result := TClassPair(inherited Items[Index]);
end;
{$ENDIF}

procedure RegisterClassSerializer(AClass : TClass; ASerializer :
    TBaseBsonSerializerClass);
begin
  Serializers.Add(TClassPair.Create(AClass, ASerializer));
end;

procedure RemoveRegisteredClassPairFromList(List: TClassPairList; AKey, AValue: TClass);
var
  i : integer;
begin
  for i := 0 to List.Count - 1 do
    if (List[i].Key = AKey) and (List[i].Value = AValue) then
      begin
        {$IFNDEF DELPHIXE}
        List[i].Free;
        {$ENDIF}
        List.Delete(i);
        exit;
      end;
end;

procedure UnRegisterClassSerializer(AClass: TClass; ASerializer : TBaseBsonSerializerClass);
begin
  RemoveRegisteredClassPairFromList(Serializers, AClass, ASerializer);
end;

function CreateClassFromKey(List: TClassPairList; AClass : TClass): TObject;
var
  i : integer;
begin
  for i := List.Count - 1 downto 0 do
    if AClass.InheritsFrom(List[i].Key) then
      begin
        Result := TBaseBsonSerializerClass(List[i].Value).Create;
        exit;
      end;
  raise EBsonSerializer.CreateFmt(SCouldNotFindClass, [AClass.ClassName]);
end;

function CreateSerializer(AClass : TClass): TBaseBsonSerializer;
begin
  Result := CreateClassFromKey(Serializers, AClass) as TBaseBsonSerializer;
end;

procedure RegisterClassDeserializer(AClass: TClass; ADeserializer:
    TBaseBsonDeserializerClass);
begin
  Deserializers.Add(TClassPair.Create(AClass, ADeserializer));
end;

procedure UnRegisterClassDeserializer(AClass: TClass; ADeserializer:
    TBaseBsonDeserializerClass);
begin
  RemoveRegisteredClassPairFromList(Deserializers, AClass, ADeserializer);
end;

function CreateDeserializer(AClass : TClass): TBaseBsonDeserializer;
begin
  Result := CreateClassFromKey(Deserializers, AClass) as TBaseBsonDeserializer;
end;

function GetAndCheckTypeData(AClass : TClass) : PTypeData;
begin
  if AClass.ClassInfo = nil then
    raise EBsonSerializationException.Create(Format(SFailedObtainingTypeDataOfObject,
      [AClass.ClassName]));
  Result := GetTypeData(AClass.ClassInfo);
  if Result = nil then
    raise EBsonSerializationException.Create(Format(SFailedObtainingTypeDataOfObject,
      [AClass.ClassName]));
  if Result.PropCount <= 0 then
    raise EBsonSerializationException.Create(SObjectHasNotPublishedProperties);
end;

function GetPropInfosDictionary(AObj: TObject): TCnvStringDictionary;
var
  PropList : PPropList;
  TypeData : PTypeData;
  i, count : integer;
  o: TObject;
  TypeInfo: PtypeInfo;
begin
  if AObj = nil then
    raise EBsonSerializationException.Create(SCanTBuildPropInfoListOfANilObjec);

  if GetPropInfosDictionaryDictionary.TryGetValue(Integer(AObj.ClassType), o) then
  begin
    Result := TCnvStringDictionary(o);
    exit;
  end;

  TypeData := GetAndCheckTypeData(AObj.ClassType);
  TypeInfo := PTypeInfo(AObj.ClassInfo);
  count := GetTypeData(PTypeInfo(AObj.ClassInfo))^.PropCount;
  Result := TCnvStringDictionary.Create;
  if count > 0 then
  begin
    GetMem(PropList, count * SizeOf(Pointer));
    GetPropInfos(TypeInfo, PropList);
    try
      for i := 0 to TypeData.PropCount - 1 do
        Result.AddOrSetValue(PropList[i].Name, TObject(PropList[i]));
      GetPropInfosDictionaryDictionary.AddOrSetValue(Integer(AObj.ClassType), Result);
    finally
      FreeMem(PropList);
    end;
  end;
end;

{ TBaseBsonSerializer }

constructor TBaseBsonSerializer.Create;
begin
  inherited Create;
end;

procedure TBaseBsonSerializer.Serialize_type(ASource: TObject);
begin
  Target.appendStr(SERIALIZED_ATTRIBUTE_ACTUALTYPE, Strip_T_FormClassName(ASource.ClassName));
end;

{ TPrimitivesBsonSerializer }

procedure TPrimitivesBsonSerializer.Serialize(const AName: string; ASource: TObject);
var
  TypeData : PTypeData;
  i : integer;
  list: PPropList;
  TypeInfo: PTypeInfo;
  count: Integer;
begin
  TypeData := GetAndCheckTypeData(ASource.ClassType);

  TypeInfo := PTypeInfo(ASource.ClassInfo);
  count := GetTypeData(PTypeInfo(ASource.ClassInfo))^.PropCount;
  if count > 0 then
  begin
    GetMem(list, count * SizeOf(Pointer));
    GetPropInfos(TypeInfo, list);
    try
      for i := 0 to TypeData.PropCount - 1 do
        SerializePropInfo(list[i], ASource);
    finally
      FreeMem(list);
    end;
  end;
end;

procedure TPrimitivesBsonSerializer.SerializePropInfo(APropInfo: PPropInfo;
    ASource: TObject);
var
  ADate : TDateTime;
  {$IFDEF DELPHI2007}
  dynArrayElementInfo: PPTypeInfo;
  {$ENDIF}
begin
  case APropInfo.PropType^.Kind of
    tkInteger : Target.append(APropInfo.Name, LongInt(GetOrdProp(ASource, APropInfo)));
    tkInt64 : Target.append(APropInfo.Name, GetInt64Prop(ASource, APropInfo));
    tkChar : Target.appendStr(APropInfo.Name, UTF8String(AnsiChar(GetOrdProp(ASource, APropInfo))));
    {$IFDEF DELPHIXE}
    tkWChar : Target.append(APropInfo.Name, UTF8String(Char(GetOrdProp(ASource, APropInfo))));
    {$ELSE}
    tkWChar : Target.appendStr(APropInfo.Name, UTF8Encode(WideChar(GetOrdProp(ASource, APropInfo))));
    {$ENDIF}
    tkEnumeration :
      {$IFDEF DELPHIXE}
      if GetTypeData(TypeInfo(Boolean)) = APropInfo^.PropType^.TypeData then
      {$ELSE}
      if APropInfo^.PropType^.Name = SBoolean then
      {$ENDIF}
        Target.append(APropInfo.Name, GetEnumProp(ASource, APropInfo) = STrue)
      else Target.appendStr(APropInfo.Name, UTF8String(GetEnumProp(ASource, APropInfo)));
    tkFloat :
      {$IFDEF DELPHIXE}
      if GetTypeData(TypeInfo(TDateTime)) = APropInfo^.PropType^.TypeData then
      {$ELSE}
      if APropInfo^.PropType^.Name = STDateTime then
      {$ENDIF}
      begin
        ADate := GetFloatProp(ASource, APropInfo);
        Target.append(APropInfo.Name, ADate);
      end
      else Target.append(APropInfo.Name, GetFloatProp(ASource, APropInfo));
    {$IFDEF DELPHIXE} tkUString, {$ENDIF}
    tkLString, tkString : Target.appendStr(APropInfo.Name, GetStrProp(ASource, APropInfo));
    {$IFDEF DELPHIXE}
    tkWString : Target.append(APropInfo.Name, UTF8String(GetWideStrProp(ASource, APropInfo)));
    {$ELSE}
    tkWString : Target.appendStr(APropInfo.Name, UTF8Encode(GetWideStrProp(ASource, APropInfo)));
    {$ENDIF}
    tkSet :
      begin
        Target.startArray(APropInfo.Name);
        SerializeSet(APropInfo, ASource);
        Target.finishObject;
      end;
    tkClass : SerializeObject(APropInfo, ASource);
    tkVariant : SerializeVariant(APropInfo, APropInfo.Name, Null, ASource);
    tkDynArray :
    begin
      {$IFNDEF DELPHI2007}
      raise EDynArrayUnsupported.Create;
      {$ELSE}
      dynArrayElementInfo := GetTypeData(APropInfo.PropType^)^.elType2;
      if (dynArrayElementInfo <> nil) and (dynArrayElementInfo^.Kind = tkClass) then
        SerializeDynamicArrayOfObjects(APropInfo, ASource) // its array of objects
      else // its array of primitives
        SerializeVariant(nil, APropInfo.Name, GetPropValue(ASource, APropInfo), ASource);
      {$ENDIF}
    end;

  end;   
end;

procedure TPrimitivesBsonSerializer.SerializeSet(APropInfo: PPropInfo; ASource:
    TObject);
var
  S : TIntegerSet;
  i : Integer;
  TypeInfo : PTypeInfo;
begin
  Integer(S) := GetOrdProp(ASource, APropInfo);
  TypeInfo := GetTypeData(APropInfo.PropType^)^.CompType^;
  for i := 0 to SizeOf(Integer) * 8 - 1 do
    if i in S then
      Target.appendStr('', GetEnumName(TypeInfo, i));
end;

procedure TPrimitivesBsonSerializer.SerializeObject(APropInfo: PPropInfo;
    ASource: TObject);
var
  SubSerializer : TBaseBsonSerializer;
  SubObject : TObject;
begin
  SubObject := GetObjectProp(ASource, APropInfo);
  SubSerializer := CreateSerializer(SubObject.ClassType);
  try
    SubSerializer.Target := Target;
    SubSerializer.Serialize(APropInfo.Name, SubObject);
  finally
    SubSerializer.Free;
  end;
end;

procedure TPrimitivesBsonSerializer.SerializeVariant(APropInfo: PPropInfo;
    const AName: String; const AVariant: Variant; ASource: TObject);
var
  v, tmp : Variant;
  i, j : integer;
  dim : integer;
begin
  if APropInfo <> nil then
    v := GetVariantProp(ASource, APropInfo)
  else v := AVariant;
  case VarType(v) of
    varNull: Target.appendNull(AName);
    varSmallInt, varInteger, {$IFDEF DELPHI2007}varShortInt, varWord, varLongWord, {$ENDIF}varByte: Target.append(AName, integer(v));
    varSingle, varDouble, varCurrency: Target.append(AName, Extended(v));
    varDate: Target.append(APropInfo.Name, TDateTime(v));
    {$IFDEF DELPHIXE} varUString, {$ENDIF}
    varOleStr, varString: Target.appendStr(AName, UTF8String(String(v)));
    varBoolean: Target.append(AName, Boolean(v));
    {$IFDEF DELPHI2007}
    {$IFDEF DELPHIXE} varUInt64, {$ENDIF}
    varInt64: Target.append(AName, TVarData(v).VInt64);
    {$ENDIF}
    else if VarType(v) and varArray = varArray then
      begin
        dim := VarArrayDimCount(v);
        Target.startArray(AName);
        for i := 1 to dim do
        begin
          if dim > 1 then
            Target.startArray('');
          for j := VarArrayLowBound(v, i) to VarArrayHighBound(v, i) do
          begin
            if dim > 1 then
              tmp := v[i - 1, j]
            else
              tmp := v[j];
            SerializeVariant(nil, '', tmp, ASource);
          end;
          if dim > 1 then
            Target.finishObject;
        end;
        Target.finishObject;
      end;
  end;
end;

{$IFDEF DELPHI2007}
procedure TPrimitivesBsonSerializer.SerializeDynamicArrayOfObjects(
  APropInfo: PPropInfo; ASource: TObject);
var
  dynArrOfObjs: TObjectDynArray;
  I: Integer;
  SubSerializer : TBaseBsonSerializer;
  scope: IScope;
begin
  scope := NewScope;
  Target.startArray(APropInfo.Name);
  dynArrOfObjs := TObjectDynArray(GetDynArrayProp(ASource, APropInfo));
  for I := Low(dynArrOfObjs) to High(dynArrOfObjs) do
  begin
    SubSerializer := scope.add(CreateSerializer(dynArrOfObjs[0].ClassType));
    SubSerializer.Target := Target;
    SubSerializer.Serialize(IntToStr(I), dynArrOfObjs[I]);
  end;
  Target.finishObject;
end;
{$ENDIF}

{ TStringsBsonSerializer }

procedure TStringsBsonSerializer.Serialize(const AName: String; ASource:
    TObject);
var
  i : integer;
  AList : TStrings;
  SubSerializer : TBaseBsonSerializer;
  SubObject : TObject;
begin
  Target.startArray(AName);
  AList := ASource as TStrings;
  for i := 0 to AList.Count - 1 do
  begin
    if AList.Objects[i] <> nil then
    begin
      Target.startObject('');
      Target.appendStr('Key', AList[i]);
      SubObject := AList.Objects[i];
      SubSerializer := CreateSerializer(SubObject.ClassType);
      try
        SubSerializer.Target := Target;
        SubSerializer.Serialize('Object', SubObject);
      finally
       SubSerializer.Free;
      end;
      Target.finishObject;
    end
    else
      Target.appendStr('', AList[i]);
  end;
  Target.finishObject;
end;

{ TDefaultObjectBsonSerializer }

procedure TDefaultObjectBsonSerializer.Serialize(const AName: String; ASource:
    TObject);
var
  PrimitivesSerializer : TPrimitivesBsonSerializer;
begin
  if AName <> '' then
    Target.startObject(AName);
  PrimitivesSerializer := TPrimitivesBsonSerializer.Create;
  try
    PrimitivesSerializer.Target := Target;
    Serialize_type(ASource); // We will always serialize _type for root object
    PrimitivesSerializer.Serialize('', ASource);
  finally
    PrimitivesSerializer.Free;
  end;
  if AName <> '' then
    Target.finishObject;
end;

{ TBaseBsonDeserializer }

constructor TBaseBsonDeserializer.Create;
begin
  inherited Create;
end;

class function TPrimitivesBsonDeserializer.BuildObject(const _Type: string; AContext: Pointer): TObject;
var
  BuilderFn : TObjectBuilderFunction;
begin
  BuilderFn := GetSerializableObjectBuilderFunction(_Type);
  if not Assigned(BuilderFn) then
    raise EBsonDeserializer.CreateFmt(SSuitableBuilderNotFoundForClass, [_Type]);
  Result := BuilderFn(_Type, AContext);
end;

{ TPrimitivesBsonDeserializer }

procedure TPrimitivesBsonDeserializer.Deserialize(var ATarget: TObject;
    AContext : Pointer);
begin
  DeserializeIterator(ATarget, AContext);
end;

procedure TPrimitivesBsonDeserializer.DeserializeIterator(var ATarget: TObject;
    AContext : Pointer);
var
  p : PPropInfo;
  {$IFDEF DELPHI2007}
  dynArrayElementInfo: PPTypeInfo;
  po : Pointer;
  {$ENDIF}
  v : Variant;
  PropInfosDictionary : TCnvStringDictionary;
  (* We need this safe function because if variant Av param represents a zero size array
     the call to DynArrayFromVariant() will fail rather than assigning nil to Apo parameter *)
  procedure SafeDynArrayFromVariant(var Apo : Pointer; const Av : Variant; ATypeInfo: Pointer);
  begin
    if VarArrayHighBound(Av, 1) - VarArrayLowBound(Av, 1) >= 0 then
      DynArrayFromVariant(Apo, Av, ATypeInfo)
    else Apo := nil;
  end;
begin
  while Source.next do
    begin
      if (ATarget = nil) and (Source.key = SERIALIZED_ATTRIBUTE_ACTUALTYPE) then
        ATarget := BuildObject(Source.value, AContext);
      PropInfosDictionary := GetPropInfosDictionary(ATarget);
      if not PropInfosDictionary.TryGetValue(Source.key, TObject(p)) then
        continue;
      if (p^.PropType^.Kind = tkVariant) and not (Source.Kind in [BSON_TYPE_ARRAY])  then
        SetVariantProp(ATarget, p, Source.value)
      else case Source.Kind of
        BSON_TYPE_INT32 : SetOrdProp(ATarget, p, Source.AsInteger);
        BSON_TYPE_BOOL : if Source.AsBoolean then
            SetEnumProp(ATarget, p, STrue)
          else SetEnumProp(ATarget, p, SFalse);
        BSON_TYPE_INT64 : SetInt64Prop(ATarget, p, Source.AsInt64);
        BSON_TYPE_UTF8, BSON_TYPE_SYMBOL : if PropInfosDictionary.TryGetValue(Source.key, TObject(p)) then
          case p^.PropType^.Kind of
            tkEnumeration : SetEnumProp(ATarget, p, Source.AsUTF8String);
            tkWString :
            {$IFDEF DELPHIXE}
            SetWideStrProp(ATarget, p, WideString(Source.AsUTF8String));
            {$ELSE}
            SetWideStrProp(ATarget, p, UTF8Decode(Source.AsUTF8String));
            {$ENDIF}
            {$IFDEF DELPHIXE}
            tkUString,
            {$ENDIF}
            tkString, tkLString : SetStrProp(ATarget, p, Source.AsUTF8String);
            tkChar : if length(Source.AsUTF8String) > 0 then
              SetOrdProp(ATarget, p, NativeInt(Source.AsUTF8String[1]));
            {$IFDEF DELPHIXE}
            tkWChar : if length(Source.value) > 0 then
              SetOrdProp(ATarget, p, NativeInt(string(Source.value)[1]));
            {$ELSE}
            tkWChar : if length(Source.value) > 0 then
              SetOrdProp(ATarget, p, NativeInt(UTF8Decode(Source.value)[1]));
            {$ENDIF}
          end;
        BSON_TYPE_DOUBLE : SetFloatProp (ATarget, p, Source.AsDouble);
        BSON_TYPE_DATE_TIME : SetFloatProp (ATarget, p, Source.AsDateTime);
        BSON_TYPE_ARRAY : case p^.PropType^.Kind of
            tkSet : DeserializeSet(p, ATarget);
            tkVariant :
            begin
              v := GetVariantProp(ATarget, p);
              DeserializeVariantArray(p, v);
              SetVariantProp(ATarget, p, v);
            end;
            tkDynArray :
            begin
              {$IFNDEF DELPHI2007}
              raise EDynArrayUnsupported.Create;
              {$ELSE}
              dynArrayElementInfo := GetTypeData(p.PropType^)^.elType2;
              //ClassType
              if (dynArrayElementInfo <> nil) and (dynArrayElementInfo^.Kind = tkClass) then
                DeserializeDynamicArrayOfObjects(p, ATarget, AContext) // it's array of objects
              else
              begin
                // it's array of primitives
                po := GetDynArrayProp(ATarget, p^.Name);
                if DynArrayDim(PDynArrayTypeInfo(p^.PropType^)) = 1 then
                begin
                  DeserializeVariantArray(p, v);
                  SafeDynArrayFromVariant(po, v, p^.PropType^);
                  SetDynArrayProp(ATarget, p, po);
                end
                else
                begin
                  DynArrayToVariant(v, po, p^.PropType^);
                  DeserializeVariantArray(p, v);
                  SafeDynArrayFromVariant(po, v, p^.PropType^);
                  SetDynArrayProp(ATarget, p, po);
                end;
              end;
              {$ENDIF}
            end;
            tkClass : DeserializeObject(p, ATarget, AContext);
          end;
        BSON_TYPE_DOCUMENT, BSON_TYPE_BINARY : if p^.PropType^.Kind = tkClass then
          DeserializeObject(p, ATarget, AContext);
      end;
    end;
end;

procedure TPrimitivesBsonDeserializer.DeserializeObject(p: PPropInfo; ATarget: TObject; AContext:
    Pointer);
var
  c: TClass;
  o: TObject;
  MustAssignObjectProperty : boolean;
begin
  {$IFNDEF DELPHI2009}
  c := GetTypeData(p.PropType^)^.ClassType;
  {$ELSE}
  c := p.PropType^.TypeData.ClassType;
  {$ENDIF}
  o := GetObjectProp(ATarget, p);
  MustAssignObjectProperty := o = nil;
  DeserializeObject(c, o, Source, AContext);
  if MustAssignObjectProperty then
    SetObjectProp(ATarget, p, o);
end;

procedure TPrimitivesBsonDeserializer.DeserializeObject(AObjClass: TClass; var AObj: TObject;
  ASource: IBsonIterator; AContext: Pointer);
var
  Deserializer : TBaseBsonDeserializer;
  _Type : string;
begin
  Deserializer := CreateDeserializer(AObjClass);
  try
    if Source.Kind in [BSON_TYPE_DOCUMENT, BSON_TYPE_ARRAY] then
      Deserializer.Source := ASource.subiterator
    else
      Deserializer.Source := ASource; // for bindata we need original BsonIterator to obtain binary handler
    if AObj = nil then
    begin
      if Source.key = SERIALIZED_ATTRIBUTE_ACTUALTYPE then
        begin
          _Type := Source.value;
          Source.next;
        end
        else
          _Type := Strip_T_FormClassName(AObjClass.ClassName);
      AObj := BuildObject(_Type, AContext);
    end;
    Deserializer.Deserialize(AObj, AContext);
  finally
    Deserializer.Free;
  end;
end;

procedure TPrimitivesBsonDeserializer.DeserializeSet(p: PPropInfo; var ATarget:
    TObject);
var
  subIt : IBsonIterator;
  setValue : string;
begin
  setValue := '[';
  subIt := Source.subiterator;
  // this is not efficient, but typically sets are going to be small entities
  while subIt.next do
    setValue := setValue + subIt.AsUTF8String + ',';
  if setValue[length(setValue)] = ',' then
    setValue[length(setValue)] := ']'
  else setValue := setValue + ']';
  SetSetProp(ATarget, p, setValue);
end;

procedure TPrimitivesBsonDeserializer.DeserializeVariantArray(p: PPropInfo; var v: Variant);
var
  subIt, currIt : IBsonIterator;
  i, j, dim : integer;
begin
  dim := GetArrayDimension(Source);
  j := 0;

  if dim > 1 then
  begin
    if dim <> VarArrayDimCount(v) then
      exit;
  end
  else
    v := VarArrayCreate([0, 256], varVariant);

  subIt := Source.subiterator;
  for i := 0 to dim - 1 do
  begin
    if dim > 1 then
    begin
      subit.next;
      currIt := subit.subiterator;
    end
    else
      currIt := subit;
    for j := VarArrayLowBound(v, dim) to VarArrayHighBound(v, dim) do
    begin
      if not currIt.next then
        break;
      if (dim = 1) and (j >= VarArrayHighBound(v, dim) - VarArrayLowBound(v, dim) + 1) then
        VarArrayRedim(v, (VarArrayHighBound(v, dim) + 1) * 2);
      if dim > 1 then
        v[i, j] := currIt.value
      else
        v[j] := currIt.value;
    end;
  end;
  if dim = 1 then
    VarArrayRedim(v, j - 1);
end;

{$IFDEF DELPHI2007}
procedure TPrimitivesBsonDeserializer.DeserializeDynamicArrayOfObjects(
  p: PPropInfo; var ATarget: TObject; AContext : Pointer);
var
  dynArrayElementInfo: PPTypeInfo;
  dynArrOfObjs: TObjectDynArray;
  I: Integer;
  it: IBsonIterator;
begin
  if Source.Kind <> BSON_TYPE_ARRAY then
    Exit;

  dynArrayElementInfo := GetTypeData(p.PropType^)^.elType2;
  dynArrOfObjs := TObjectDynArray(GetDynArrayProp(ATarget, p));
  SetLength(dynArrOfObjs, 256);
  I := 0;
  it := Source.subiterator;
  while it.next and (it.Kind = BSON_TYPE_DOCUMENT) do
  begin
    if I > Length(dynArrOfObjs) then
      SetLength(dynArrOfObjs, I * 2);
    DeserializeObject(GetTypeData(dynArrayElementInfo^)^.ClassType,
                      dynArrOfObjs[I], it, AContext);
    Inc(I);
  end;
  SetLength(dynArrOfObjs, I);
  SetDynArrayProp(ATarget, p, dynArrOfObjs);
end;
{$ENDIF}

function TPrimitivesBsonDeserializer.GetArrayDimension(it: IBsonIterator) : Integer;
begin
  Result := 0;
  while it.Kind = BSON_TYPE_ARRAY do
  begin
    Inc(Result);
    it := it.subiterator;
    if not it.next then
      Exit;
  end;
end;

{ TStringsBsonDeserializer }

procedure TStringsBsonDeserializer.Deserialize(var ATarget: TObject; AContext: Pointer);
var
  AStrings : TStrings;
begin
  AStrings := ATarget as TStrings;
  while Source.next do
    AStrings.Add(Source.AsUTF8String);
end;

{ TStreamBsonSerializer }

procedure TStreamBsonSerializer.Serialize(const AName: String; ASource: TObject);
var
  Stream : TStream;
  Data : Pointer;
begin
  Stream := ASource as TStream;
  if Stream.Size > 0 then
    GetMem(Data, Stream.Size)
  else
    Data := nil;
  try
    if Data <> nil then
      begin
        Stream.Position := 0;
        Stream.Read(Data^, Stream.Size);
      end;
    Target.appendBinary(AName, BSON_SUBTYPE_BINARY, Data, Stream.Size);
  finally
    if Data <> nil then
      FreeMem(Data);
  end;
end;

{ TStreamBsonDeserializer }

procedure TStreamBsonDeserializer.Deserialize(var ATarget: TObject; AContext: Pointer);
var
  binData : IBsonBinary;
  Stream : TStream;
begin
  binData := Source.asBinary;
  Stream := ATarget as TStream;
  Stream.Size := binData.Len;
  Stream.Position := 0;
  if binData.Len > 0 then
    Stream.Write(binData.Data^, binData.Len);
end;

{ TObjectAsStringListBsonSerializer }

procedure TObjectAsStringListBsonSerializer.Serialize(const AName: String;
    ASource: TObject);
var
  i : integer;
  AList : TStrings;
begin
  Target.startObject(AName);
  AList := ASource as TStringList;
  for i := 0 to AList.Count - 1 do
    Target.appendStr(AList.Names[i], {$IFDEF DELPHI2007}AList.ValueFromIndex[i]{$ELSE}AList.Values[AList.Names[I]]{$ENDIF});
  Target.finishObject;
end;

{ TObjectAsStringListBsonDeserializer }

procedure TObjectAsStringListBsonDeserializer.Deserialize(var ATarget: TObject;
    AContext: Pointer);
var
  AStrings : TStrings;
begin
  AStrings := ATarget as TStrings;
  while Source.next do
    AStrings.Add(Source.key + '=' + Source.AsUTF8String);
end;

procedure RegisterBuildableSerializableClass(const AClassName : string;
    ABuilderFunction : TObjectBuilderFunction);
var
  BuilderFunctionAsPointer : pointer absolute ABuilderFunction;
begin
  BuilderFunctions.AddOrSetValue(Strip_T_FormClassName(AClassName), TObject(BuilderFunctionAsPointer));
end;

procedure UnregisterBuildableSerializableClass(const AClassName : string);
begin
  BuilderFunctions.Remove(Strip_T_FormClassName(AClassName));
end;

procedure DestroyPropInfosDictionaryCache;
var
  i : integer;
begin
  for i := 0 to PropInfosDictionaryCacheTrackingList.Count - 1 do
    TCnvIntegerDictionary(PropInfosDictionaryCacheTrackingList[i]).Free;
end;

{ TCnvStringDictionarySerializer }

procedure TCnvStringDictionarySerializer.SerializeKeyValuePairSimple(const AKey: string;
  const AValue: TObject; AUserData: Pointer);
begin
  SerializeValue(AKey, AValue);
end;

procedure TCnvStringDictionarySerializer.SerializeKeyValuePairComplex(const AKey: string;
  const AValue: TObject; AUserData: Pointer);
begin
  Target.startObject(SERIALIZED_ATTRIBUTE_COLLECTION_KEY + SERIALIZED_ATTRIBUTE_COLLECTION_VALUE);
    Target.startObject(SERIALIZED_ATTRIBUTE_COLLECTION_KEY);
      Target.appendStr(AValue.ClassName, AKey);
    Target.finishObject;
    Target.startObject(SERIALIZED_ATTRIBUTE_COLLECTION_VALUE);
      SerializeValue(AValue.ClassName, AValue);
    Target.finishObject;
  Target.finishObject;
end;

procedure TCnvStringDictionarySerializer.SerializeValue(const AKey: string;
  const AValue: TObject);
var
  serializer: TBaseBsonSerializer;
begin
  if AValue is TPrimitiveWrapper then
  begin
    // serialize wrappers as primitives
    if AValue is TStringWrapper then
      Target.appendStr(AKey, TStringWrapper(AValue).Value)
    else if AValue is TIntegerWrapper then
      Target.append(AKey, TIntegerWrapper(AValue).Value)
    else if AValue is TInt64Wrapper then
      Target.append(AKey, TInt64Wrapper(AValue).Value)
    else if AValue is TDoubleWrapper then
      Target.append(AKey, TDoubleWrapper(AValue).Value)
    else if AValue is TBooleanWrapper then
      Target.append(AKey, TBooleanWrapper(AValue).Value)
    else if AValue is TDateTimeWrapper then
      Target.appendDate(AKey, TDateTimeWrapper(AValue).Value)
    else
      raise Exception.Create('Unable to serialize primitive wrapper');
  end
  else
  begin
    // serialize object
    serializer := CreateSerializer(AValue.ClassType);
    try
      serializer.Target := Target;
      serializer.Serialize(AKey, AValue);
    finally
      serializer.Free;
    end;
  end;
end;

procedure TCnvStringDictionarySerializer.Serialize(const AName: String;
  ASource: TObject);
var
  callback: TCnvStringDictionaryEnumerateCallback;
begin
  if not (ASource is TCnvStringDictionary) then
    Exit;

  if DictionarySerializationMode = ForceComplex then
    callback := SerializeKeyValuePairComplex
  else
    callback := SerializeKeyValuePairSimple;

  with Target do
  begin
    startObject(AName);
    TCnvStringDictionary(ASource).Foreach(callback);
    finishObject;
  end;
end;

{ TCnvStringDictionaryDeserializer }

procedure TCnvStringDictionaryDeserializer.Deserialize(var ATarget: TObject;
  AContext: Pointer);
var
  dict: TCnvStringDictionary;
begin
  if not (ATarget is TCnvStringDictionary) then
    Exit;

  dict := TCnvStringDictionary(ATarget);
  if DictionarySerializationMode = ForceComplex then
    ComplexDeserialize(dict, AContext)
  else
    SimpleDeserialize(dict, AContext);
end;

procedure TCnvStringDictionaryDeserializer.ComplexDeserialize(
  var ADic: TCnvStringDictionary; AContext: Pointer);
var
  key: string;
  subit, keyit, valit: IBsonIterator;
begin
  while Source.next do
  begin
    if (Source.kind <> BSON_TYPE_DOCUMENT) and (Source.kind <> BSON_TYPE_ARRAY) then
      continue;

    subit := Source.subiterator;
    key := '';
    valit := nil;
    while subit.next and (subit.kind = BSON_TYPE_DOCUMENT) do
    begin
      if subit.key = SERIALIZED_ATTRIBUTE_COLLECTION_KEY then
      begin
        keyit := subit.subiterator;
        keyit.next;
        if keyit.kind <> BSON_TYPE_UTF8 then
          raise EBsonSerializer.Create('Only string key supported for ' + TCnvStringDictionary.ClassName);
        key := keyit.AsUTF8String;
      end
      else if subit.key = SERIALIZED_ATTRIBUTE_COLLECTION_VALUE then
      begin
        valit := subit.subiterator;
        valit.next;

      end;
    end;
    if (key <> '') and (valit <> nil) then
      DeserializeValue(ADic, AContext, valit, key);
  end;
end;

class procedure TCnvStringDictionaryDeserializer.DeserializeValue(var ADic: TCnvStringDictionary; AContext: Pointer;
  it: IBsonIterator; const AKey: string);
var
  deserializer: TBaseBsonDeserializer;
  obj: TObject;
  subit: IBsonIterator;
begin
  with ADic do
    case it.Kind of
      BSON_TYPE_UTF8: AddOrSetValue(AKey, it.AsUTF8String);
      BSON_TYPE_INT32: AddOrSetValue(AKey, it.AsInteger);
      BSON_TYPE_INT64: AddOrSetValue(AKey, it.AsInt64);
      BSON_TYPE_DOUBLE: AddOrSetValue(AKey, it.AsDouble);
      BSON_TYPE_BOOL: AddOrSetValue(AKey, it.AsBoolean);
      BSON_TYPE_DATE_TIME: AddOrSetValueDate(AKey, it.AsDateTime);
      BSON_TYPE_DOCUMENT:
      begin
        subit := it.subiterator;
        obj := nil;
        deserializer := CreateDeserializer(TObject);
        try
          deserializer.Source := subit;
          deserializer.Deserialize(obj, AContext);
        finally
          deserializer.Free;
        end;
        AddOrSetValue(AKey, obj);
      end;
      else
        raise Exception.Create('Unable to deserialize primitive wrapper');
    end;
end;

procedure TCnvStringDictionaryDeserializer.SimpleDeserialize(
  var ADic: TCnvStringDictionary; AContext: Pointer);
begin
  while Source.next do
    DeserializeValue(ADic, AContext, Source, Source.key);
end;

initialization
  DictionarySerializationMode := Simple;

  PropInfosDictionaryCacheTrackingListLock := TCriticalSection.Create;
  PropInfosDictionaryCacheTrackingList := TList.Create;
  BuilderFunctions := TCnvStringDictionary.Create;
  Serializers := TClassPairList.Create;
  Deserializers := TClassPairList.Create;
  RegisterClassSerializer(TObject, TDefaultObjectBsonSerializer);
  RegisterClassSerializer(TStrings, TStringsBsonSerializer);
  RegisterClassSerializer(TStream, TStreamBsonSerializer);
  RegisterClassSerializer(TObjectAsStringList, TObjectAsStringListBsonSerializer);
  RegisterClassSerializer(TCnvStringDictionary, TCnvStringDictionarySerializer);
  RegisterClassDeserializer(TObject, TPrimitivesBsonDeserializer);
  RegisterClassDeserializer(TStrings, TStringsBsonDeserializer);
  RegisterClassDeserializer(TStream, TStreamBsonDeserializer);
  RegisterClassDeserializer(TObjectAsStringList, TObjectAsStringListBsonDeserializer);
  RegisterClassDeserializer(TCnvStringDictionary, TCnvStringDictionaryDeserializer);
finalization
  DestroyPropInfosDictionaryCache;
  UnRegisterClassDeserializer(TCnvStringDictionary, TCnvStringDictionaryDeserializer);
  UnRegisterClassDeserializer(TStream, TStreamBsonDeserializer);
  UnRegisterClassDeserializer(TObject, TPrimitivesBsonDeserializer);
  UnRegisterClassDeserializer(TStrings, TStringsBsonDeserializer);
  UnRegisterClassDeserializer(TObjectAsStringList, TObjectAsStringListBsonDeserializer);
  UnRegisterClassSerializer(TCnvStringDictionary, TCnvStringDictionarySerializer);
  UnRegisterClassSerializer(TStream, TStreamBsonSerializer);
  UnRegisterClassSerializer(TStrings, TStringsBsonSerializer);
  UnRegisterClassSerializer(TObject, TDefaultObjectBsonSerializer);
  UnRegisterClassSerializer(TObjectAsStringList, TObjectAsStringListBsonSerializer);
  Deserializers.Free;
  Serializers.Free;
  BuilderFunctions.Free;
  PropInfosDictionaryCacheTrackingList.Free;
  PropInfosDictionaryCacheTrackingListLock.Free;
end.

