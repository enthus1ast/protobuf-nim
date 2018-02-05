import streams, strutils, sequtils, macros

type
  VarInt = distinct uint64
  SVarInt = distinct int64

when cpuEndian == littleEndian:
  proc hob(x: VarInt): int =
    result = x.int
    result = result or (result shr 1)
    result = result or (result shr 2)
    result = result or (result shr 4)
    result = result or (result shr 8)
    result = result or (result shr 16)
    result = result or (result shr 32)
    result = result - (result shr 1)

  proc write(s: Stream, x: VarInt) =
    var
      bytes = x.hob shr 7
      num = x.int64
    s.write((num and 0x7f or 0x80).uint8)
    while bytes > 0:
      num = num shr 7
      bytes = bytes shr 7
      s.write((num and 0x7f or (if bytes > 0: 0x80 else: 0)).uint8)

  proc readVarInt(s: Stream): VarInt =
    var
      byte = s.readInt8()
      i = 1
    result = (byte and 0x7f).VarInt
    while (byte and 0x80) != 0:
      # TODO: Add error checking for values not fitting 64 bits
      byte = s.readInt8()
      result = (result.uint64 or ((byte.uint64 and 0x7f) shl (7*i))).VarInt
      i += 1

  proc write(s: Stream, x: SVarInt) =
    # TODO: Ensure that this works for all int64 values
    var t = x.int64 * 2
    if x.int64 < 0:
      t = t xor -1
    s.write(t.VarInt)

  proc readSVarInt(s: Stream): SVarInt =
    let y = s.readVarInt().uint64
    return ((y shr 1) xor (if (y and 1) == 1: (-1).uint64 else: 0)).SVarInt

when isMainModule:
  import "../combparser/combparser"
  import lists

  proc ignorefirst(first, catch: StringParser[string]): StringParser[string] =
    (first + catch).map(proc(input: tuple[f1, f2: string]): string = input.f2) / catch

  proc ignorelast(catch, last: StringParser[string]): StringParser[string] =
    (catch + last).map(proc(input: tuple[f1, f2: string]): string = input.f1) / catch

  proc andor(first, last: StringParser[string]): StringParser[string] =
    (first + last).map(proc(input: tuple[f1, f2: string]): string = input.f1 & input.f2) /
      (first / last)

  proc ws(value: string): StringParser[string] =
    regex(r"\s*" & value & r"\s*")

  proc combine(list: seq[string], sep: string): string =
    result = ""
    for entry in list:
      result = result & entry & sep
    result = result[0..^(sep.len + 1)]

  proc combine(list: seq[string]): string =
    list.combine("")

  proc combine(t: tuple[f1, f2: string]): string = t.f1 & t.f2

  proc combine[T](t: tuple[f1: T, f2: string]): string = t.f1.combine() & t.f2

  proc combine[T](t: tuple[f1: string, f2: T]): string = t.f1 & t.f2.combine()

  proc combine[T, U](t: tuple[f1: T, f2: U]): string = t.f1.combine() & t.f2.combine()

  proc endcomment(): StringParser[string] = regex(r"\s*//.*\s*").repeat(1).map(combine)

  proc inlinecomment(): StringParser[string] = regex(r"\s*/\*.*\*/\s*").repeat(1).map(combine)

  proc comment(): StringParser[string] = andor(endcomment(), inlinecomment()).repeat(1).map(combine)

  proc endstatement(): StringParser[string] =
    ignorefirst(inlinecomment(), ws(";")).ignorelast(comment())

  proc str(): StringParser[string] =
    ignorefirst(inlinecomment(), regex(r"\s*\""[^""]*\""\s*")).map(
      proc(n: string): string =
        n.strip()[1..^2]
    ).ignorelast(comment())

  proc number(): StringParser[string] = regex(r"\s*[0-9]+\s*").map(proc(n: string): string =
    n.strip())

  proc strip(input: string): string =
    input.strip(true, true)

  proc enumname(): StringParser[string] =
    ignorefirst(comment(), regex(r"\s*[A-Z]*\s*")).ignorelast(comment()).map(strip)

  proc token(): StringParser[string] =
    ignorefirst(comment(), regex(r"\s*[a-z][a-zA-Z0-9_]*\s*")).ignorelast(comment()).map(strip)

  proc token(name: string): StringParser[string] =
    ignorefirst(comment(), ws(name)).ignorelast(comment()).map(strip)

  proc class(): StringParser[string] =
    ignorefirst(inlinecomment(), regex(r"\s*[A-Z][a-zA-Z0-9_]*\s*")).ignorelast(comment()).map(strip)

  type
    ProtoType = enum
      Field, Enum, EnumVal, ReservedBlock, Reserved, Message, File
    ReservedType = enum
      String, Number
    ProtoNode = ref object
      case kind*: ProtoType
      of Field:
        number: int
        protoType: string
        name: string
      of Enum:
        enumName: string
        values: seq[ProtoNode]
      of EnumVal:
        fieldName: string
        num: int
      of ReservedBlock:
        resValues: seq[ProtoNode]
      of Reserved:
        case reservedKind*: ReservedType
        of ReservedType.String:
          strVal: string
        of ReservedType.Number:
          intVal: int
      of Message:
        messageName: string
        reserved: seq[ProtoNode]
        definedEnums: seq[ProtoNode]
        fields: seq[ProtoNode]
      of File:
        syntax: string
        messages: seq[ProtoNode]

  proc `$`(node: ProtoNode): string =
    case node.kind:
      of Field:
        result = "Field $1 of type $2 with index $3".format(
          node.name,
          node.protoType,
          node.number)
      of Enum:
        result = "Enum $1 has values:\n".format(
          node.enumName)
        var fields = ""
        for field in node.values:
          fields &= $field & "\n"
        result &= fields[0..^2].indent(1, "  ")
      of EnumVal:
        result = "Enum field $1 with index $2".format(
          node.fieldName,
          node.num)
      of ReservedBlock:
        result = "Reserved values:\n"
        var reserved = ""
        for value in node.resValues:
          reserved &= $value & "\n"
        result &= reserved.indent(1, "  ")
      of Reserved:
        result = case node.reservedKind:
          of ReservedType.String:
            "Reserved field name $1".format(
              node.strVal)
          of ReservedType.Number:
            "Reserved field index $1".format(
              node.intVal)
      of Message:
        result = "Message $1 with reserved fields:\n".format(
          node.messageName)
        var reserved = ""
        for res in node.reserved:
          reserved &= $res & "\n"
        result &= reserved[0..^2].indent(1, "  ")
        var enums = "\n"
        for definedEnum in node.definedEnums:
          enums &= $definedEnum & "\n"
        result &= enums[0..^2].indent(1, "  ")
        var fields = "\n"
        for field in node.fields:
          fields &= $field & "\n"
        result &= fields[0..^2].indent(1, "  ")
      of File:
        result = "Protobuf file with syntax $1 and messages:\n".format(
          node.syntax)
        var body = ""
        for message in node.messages:
          body &= $message & "\n"
        result &= body.indent(1, "  ")

  proc syntaxline(): StringParser[string] = (token("syntax") + ws("=") + str() + endstatement()).map(
    proc (stuple: auto): string =
      stuple[0][1]
  )

  proc declaration(): StringParser[ProtoNode] = ((token() / class()) + token() + ws("=") + number() + endstatement()).map(
    proc (input: auto): ProtoNode =
      result = ProtoNode(kind: Field, number: parseInt(input[0][1]), name: input[0][0][0][1], protoType: input[0][0][0][0])
  )

  proc reserved(): StringParser[ProtoNode] = (token("reserved") + ((number().ignorelast(ws(","))).repeat(1) / (str().ignorelast(ws(","))).repeat(1)) + endstatement()).map(
    proc (rtuple: ((string, seq[string]), string)): ProtoNode =
      result = ProtoNode(kind: ReservedBlock, resValues: @[])
      var num: int
      for reserved in rtuple[0][1]:
        try:
          num = parseInt(reserved)
          result.resValues.add ProtoNode(kind: Reserved, reservedKind: ReservedType.Number, intVal: num)
        except:
          result.resValues.add ProtoNode(kind: Reserved, reservedKind: ReservedType.String, strVal: reserved)
  )

  proc enumvals(): StringParser[ProtoNode] = (enumname() + ws("=") + number() + endstatement()).map(
    proc (input: auto): ProtoNode =
      result = ProtoNode(kind: EnumVal, fieldName: input[0][0][0], num: parseInt(input[0][1]))
  )

  proc enumblock(): StringParser[ProtoNode] = (token("enum") + class() + ws("{") + enumvals().repeat(1) + ws("}")).map(
    proc (input: auto): ProtoNode =
      result = ProtoNode(kind: Enum, enumName: input[0][0][0][1], values: input[0][1])
  )

  proc messageblock(): StringParser[ProtoNode] = (token("message") + class() + ws("{") + (declaration() / reserved() / enumblock()).repeat(0) + ws("}")).map(
    proc (input: auto): ProtoNode =
      result = ProtoNode(kind: Message, messageName: input[0][0][0][1], reserved: @[], definedEnums: @[], fields: @[])
      for thing in input[0][1]:
        case thing.kind:
        of ReservedBlock:
          result.reserved = result.reserved.concat(thing.resValues)
        of Enum:
          result.definedEnums.add thing
        of Field:
          result.fields.add thing
        else:
          continue
  )

  proc protofile(): StringParser[ProtoNode] = (syntaxline() + messageblock().repeat(1)).map(
    proc (input: auto): ProtoNode =
      result = ProtoNode(kind: File, syntax: input[0], messages: @[])
      for message in input[1]:
        result.messages.add message
  )

  #echo parse(ignorefirst(comment(), s("syntax")) , "syntax = \"This is syntax\";")
  echo parse(syntaxline(), "syntax = \"This is syntax\";")
  echo parse(declaration(), "int32 syntax = 5;")
  echo parse(reserved(), "reserved 5;")
  echo parse(reserved(), "reserved 5, 7;")
  echo parse(reserved(), "reserved \"foo\";")
  echo parse(reserved(), "reserved \"foo\", \"bar\";")
  echo parse(enumvals(), "TEST = 4;")
  echo parse(enumblock(), """enum Test {
    TEST = 5;
    FOO = 6;
    BAR = 9;
  }
  """")

  var protoStr = readFile("proto3.prot")
  echo parse(protofile(), protoStr)
  #echo parse(regex(r"\s*/\*.*\*/\s*"), "/* THis is a test */")
  #echo parse(regex(r"\s*//.*\s*").repeat(1).map(combine), """// This is a test
  #// Test""")



when false:#isMainModule:
  var
    ss = newStringStream()
    num = (0x99_e1).VarInt
  ss.write(num)
  ss.setPosition(0)
  let vi = ss.readVarInt()
  echo vi.toHex
  echo vi.uint64
  echo "--"

  var
    x = 1000
    y = -1000
  echo(((x shl 1) xor (x shr 31)).uint32)
  echo(((y shl 1) xor (y shr 31)).uint32)
  let
    num2 = (-2147483648).SVarInt
    pos = ss.getPosition()
  ss.write(num2)
  ss.setPosition(pos)
  let svi = ss.readSVarInt()
  echo "---"
  echo $svi.int64
  echo "----"

  ss.setPosition(0)
  for c in ss.readAll():
    echo c.toHex
  for i in countup(0, 1000, 255):
    echo $i & ":\t" & $(i.VarInt.hob)

  import strutils, pegs
  # Read in the protobuf specification
  var proto = readFile("proto3.prot")
  # Remove the comments
  proto = proto.replacef(peg"'/*' @ '*/' / '//' @ \n / \n", "")
  type
    ProtoSymbol = enum
      Undefined
      Syntax = "syntax", Proto2 = "proto2", Proto3 = "proto3"
      Int32 = "int32", Int64 = "int64", Uint32 = "uint32"
      Uint64 = "uint64", Sint32 = "sint32", Sint64 = "sint64"
      Bool = "bool", Enum = "enum", Fixed64 = "fixed64", Sfixed64 = "sfixed64"
      Fixed32 = "fixed32", Sfixed32 = "sfixed32", Bytes = "bytes"
      Double = "double", Float = "float", String = "string"
      Message = "message", Reserved = "reserved", Repeated = "repeated"
      Option = "option", Import = "import", OneOf = "oneof", Map = "map"
      Package = "package", Service = "service", RPC = "rpc", Returns = "returns"

    FieldNode = ref object
      name: string
      kind: ProtoSymbol
      num: int

    MessageNode = ref object
      name: string
      fields: seq[FieldNode]

  const
    ProtoTypes = {Int32, Int64, Uint32, Uint64, Sint32, Sint64, Fixed32, Fixed64,
      Sfixed32, Sfixed64, Bool, Bytes, Enum, Float, Double, String}
    Unimplemented = {Option, Import, OneOf, Map, Package, Service, RPC, Returns, Proto2, Reserved, Repeated}
    FirstToken = {Syntax, Message, Service, Package, Import}
    SyntaxSpecifier = {Proto2, Proto3}

  proc contains(x: set[ProtoSymbol], y: string): bool =
    for s in x:
      if y == $s:
        return true
    return false

  proc startsWith(x: string, y: set[ProtoSymbol]): bool =
    for s in y:
      if x.startsWith($s):
        return true
    return false

  var
    syntax: ProtoSymbol
    currentMessage: MessageNode
    blockLevel = 0
  # Tokenize
  for t in proto.tokenize({'{', '}', ';'}):
    if t.token.isSpaceAscii:
      continue
    let
      token = t.token.strip
      isSep = t.isSep
    if syntax == Undefined:
      let s = token.split('=')
      assert(s.len == 2, "First non-empty, non-comment statement must be a syntax specifier.")
      assert(s[0].strip == $Syntax, "First non-empty, non-comment statement must be a syntax specifier.")
      var specifier = s[1].strip
      assert(specifier[0] == '"' and specifier[^1] == '"', "Unknown syntax " & $specifier)
      specifier = specifier[1..^2]
      assert(specifier in SyntaxSpecifier, "Unknown syntax " & $specifier)
      assert(specifier notin Unimplemented, "This parser does not support syntax " & $specifier)
      syntax = parseEnum[ProtoSymbol](specifier)
    else:
      if isSep:
        for c in token:
          if c == '{':
            blockLevel += 1
          if c == '}':
            blockLevel -= 1
      else:
        if blockLevel == 0:
          if token.startsWith(Unimplemented):
            stderr.write("Unimplemented feature: " & token & "\n")
            continue
          assert(token.startsWith(FirstToken), "Misplaced token \"" & token & "\"")
          if token.startsWith($Message):
            assert(currentMessage == nil, "Recursive message not allowed: " & token)
            currentMessage = new MessageNode
            let s = token.split()
            assert(s.len == 2, "Unknown message syntax, only \"message <identifier>\" is allowed: " & token)
            currentMessage.name = s[1]
            currentMessage.fields = @[]
          continue
        else:
          echo $blockLevel & " token: " & $token
          if token.startsWith(Unimplemented):
            stderr.write("Unimplemented feature: " & token & "\n")
            continue
          if currentMessage == nil:
            continue
          if not token.startsWith(ProtoTypes):
            stderr.write("Unknown type in message, currently only basic types are allowed: " & token & "\n")
            continue
          let s = token.split()
          if token.startsWith($Enum):
            stderr.write("Enums not implemented yet: " & $token & "\n")
            continue
          assert(s.len == 4, "Unknown definition of basic type: " & $token)
          assert(s[2] == "=", "Basic type needs field number: " & $token)
          var field = new FieldNode
          field.name = s[1]
          field.kind = parseEnum[ProtoSymbol](s[0])
          assert(field.kind in ProtoTypes, "Unknown type: " & token)
          field.num = parseInt(s[3])
          currentMessage.fields.add field



  echo syntax
  if currentMessage != nil:
    echo currentMessage.name
    for field in currentMessage.fields:
      echo field.name

