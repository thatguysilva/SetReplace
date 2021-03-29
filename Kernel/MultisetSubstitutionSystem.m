Package["SetReplace`"]

PackageImport["GeneralUtilities`"]

PackageExport["MultisetSubstitutionSystem"]

SetUsage @ "
MultisetSubstitutionSystem[{pattern$1, pattern$2, $$} :> output$] is a rewriting system that replaces subsets with \
elements matching pattern$1, pattern$2, $$ by a list produced by evaluating output$, where pattern$i can be matched in \
any order.
MultisetSubstitutionSystem should be used as the first argument in functions such as GenerateMultihistory.
";

SyntaxInformation[MultisetSubstitutionSystem] = {"ArgumentsPattern" -> {rules_}};

declareMultihistoryGenerator[
  generateMultisetSubstitutionSystem,
  MultisetSubstitutionSystem,
  <|"MaxGeneration" -> {Infinity, "NonNegativeIntegerOrInfinity"},
    "MaxDestroyerEvents" -> {Infinity, "NonNegativeIntegerOrInfinity"},
    "MinEventInputs" -> {0, "NonNegativeIntegerOrInfinity"},
    "MaxEventInputs" -> {Infinity, "NonNegativeIntegerOrInfinity"}|>,
  {"InputCount", "SortedInputExpressions", "UnsortedInputExpressions", "RuleIndex"},
  <|"MaxEvents" -> {Infinity, "NonNegativeIntegerOrInfinity"}|>];

generateMultisetSubstitutionSystem[MultisetSubstitutionSystem[rawRules___],
                                   rawEventSelection_,
                                   rawTokenDeduplication_,
                                   rawEventOrdering_,
                                   rawStoppingCondition_,
                                   rawInit_] := ModuleScope[
  rules = parseRules[rawRules];
  {maxGeneration, maxDestroyerEvents, minEventInputs, maxEventInputs} = Values @ rawEventSelection;
  tokenDeduplication = parseTokenDeduplication[rawTokenDeduplication];
  parseEventOrdering[rawEventOrdering];           (* Event ordering is not implemented at the moment *)
  {maxEvents} = Values @ rawStoppingCondition;
  init = parseInit[rawInit];

  expressions = CreateDataStructure["DynamicArray", init];
  expressionContentsToIndices = CreateDataStructure["HashTable"];
  MapThread[insertWholeExpressionToIndex[expressionContentsToIndices], {Range @ Length @ init, init}];
  eventRuleIndices = CreateDataStructure["DynamicArray", {0}]; (* the first event is the initial event *)
  eventInputs = CreateDataStructure["DynamicArray", {{}}];
  eventOutputs = CreateDataStructure["DynamicArray", {Range @ Length @ init}];
  eventGenerations = CreateDataStructure["DynamicArray", {0}];
  expressionCreatorEvents =
    CreateDataStructure["DynamicArray", Table[CreateDataStructure["DynamicArray", {1}], Length @ init]];
  expressionDestroyerEventCounts = CreateDataStructure["DynamicArray", ConstantArray[0, Length @ init]];
  (* eventDestroyerChoices[expressionID][expressionID] -> eventID. See libSetReplace/Event.cpp for more information. *)
  expressionDestroyerChoices =
    CreateDataStructure["DynamicArray", Table[CreateDataStructure["HashTable"], Length @ init]];
  eventInputsHashSet = CreateDataStructure["HashSet", {{}}];

  (* Data structures are modified in-place. If the system runs out of matches, it throws an exception. *)
  conclusionReason = Catch[
    Do[
      evaluateSingleEvent[rules, maxGeneration, maxDestroyerEvents, minEventInputs, maxEventInputs, tokenDeduplication][
          expressions,
          expressionContentsToIndices,
          eventRuleIndices,
          eventInputs,
          eventOutputs,
          eventGenerations,
          expressionCreatorEvents,
          expressionDestroyerEventCounts,
          expressionDestroyerChoices,
          eventInputsHashSet],
      Replace[maxEvents, Infinity -> 2^63 - 1]];
    "MaxEvents"
  ,
    $$conclusionReason
  ];

  Multihistory[
    {MultisetSubstitutionSystem, 0},
    <|"Rules" -> rules,
      "ConclusionReason" -> conclusionReason,
      "Expressions" -> expressions,
      "ExpressionContentsToIndices" -> expressionContentsToIndices,
      "EventRuleIndices" -> eventRuleIndices,
      "EventInputs" -> eventInputs,
      "EventOutputs" -> eventOutputs,
      "EventGenerations" -> eventGenerations,
      "ExpressionCreatorEvents" -> expressionCreatorEvents,
      "ExpressionDestroyerEventCounts" -> expressionDestroyerEventCounts,
      "ExpressionDestroyerChoices" -> expressionDestroyerChoices,
      "EventInputsHashSet" -> eventInputsHashSet|>]
];

insertWholeExpressionToIndex[expressionContentsToIndices_][index_, expression_] :=
  If[expressionContentsToIndices["KeyExistsQ", expression],
    expressionContentsToIndices["Lookup", expression]["Append", index];
  ,
    expressionContentsToIndices["Insert", expression -> CreateDataStructure["DynamicArray", {index}]];
  ];

(* Evaluation *)

evaluateSingleEvent[
      rules_, maxGeneration_, maxDestroyerEvents_, minEventInputs_, maxEventInputs_, tokenDeduplication_][
    expressions_,
    expressionContentsToIndices_,
    eventRuleIndices_,
    eventInputs_,
    eventOutputs_,
    eventGenerations_,
    expressionCreatorEvents_,
    expressionDestroyerEventCounts_,
    expressionDestroyerChoices_,
    eventInputsHashSet_] := ModuleScope[
  {ruleIndex, matchedExpressions} = findMatch[rules, maxGeneration, maxDestroyerEvents, minEventInputs, maxEventInputs][
    expressions,
    eventGenerations,
    expressionCreatorEvents,
    expressionDestroyerEventCounts,
    expressionDestroyerChoices,
    eventInputsHashSet];
  createEvent[rules, ruleIndex, matchedExpressions, tokenDeduplication][expressions,
                                                                        expressionContentsToIndices,
                                                                        eventRuleIndices,
                                                                        eventInputs,
                                                                        eventOutputs,
                                                                        eventGenerations,
                                                                        expressionCreatorEvents,
                                                                        expressionDestroyerEventCounts,
                                                                        expressionDestroyerChoices,
                                                                        eventInputsHashSet]
];

(* Matching *)

findMatch[rules_, maxGeneration_, maxDestroyerEvents_, minEventInputs_, maxEventInputs_][
    expressions_,
    eventGenerations_,
    expressionCreatorEvents_,
    expressionDestroyerEventCounts_,
    expressionDestroyerChoices_,
    eventInputsHashSet_] := ModuleScope[
  eventInputsCountRange = {minEventInputs, Min[maxEventInputs, expressions["Length"]]};
  subsetCount = With[{n = expressions["Length"], a = eventInputsCountRange[[1]], b = eventInputsCountRange[[2]]},
    (* Sum[Binomial[n, k], {k, a, b}] *)
    Binomial[n, a] * Hypergeometric2F1[1, a - n, 1 + a, -1] -
      Binomial[n, 1 + b] * Hypergeometric2F1[1, 1 + b - n, 2 + b, -1]
  ];

  (* Matching is currently rather inefficient, because it enumerates all subsets no matter what.
     Three things need to happen to make it faster:
     1. We need to do some rule introspection to determine what to search for. For example, for some rules, we can
        automatically determine the number of input expressions, in which case we don't have to enumerate all subsets
        anymore. We can also make an atoms index for some rules (like we do in Matcher of libSetReplace). In this case,
        we can avoid searching entire subtrees if we see some expressions as non-intersecting.
     2. We need to skip expressions from matching based on metadata. For example, we shouldn't continue matching groups
        that are not spacelike or have exceeding generations or destroyer event count.
     3. We need to save partial searching results. They can probably be saved as non-intersecting ranges. Note that they
        have to be ranges because adding new expressions will introduce gaps in the sequence of matches ordered
        according to some (but not all) ordering functions. This new data structure will replace eventInputsHashSet. *)
  ScopeVariable[subsetIndex, possibleMatch, ruleIndex];
  Do[
    If[!eventInputsHashSet["MemberQ", {ruleIndex, possibleMatch}] &&
        AllTrue[expressionDestroyerEventCounts["Part", #] & /@ possibleMatch, # < maxDestroyerEvents &] &&
        AllTrue[possibleMatch, expressionGeneration[eventGenerations, expressionCreatorEvents][#] < maxGeneration &] &&
        MatchQ[expressions["Part", #] & /@ possibleMatch, rules[[ruleIndex, 1]]] &&
        spacelikeExpressionsQ[expressionDestroyerChoices][possibleMatch],
      Return[{ruleIndex, possibleMatch}, Module]
    ];
  ,
    {subsetIndex, 1, Min[subsetCount, 2 ^ 63 - 1]},
    {possibleMatch, Permutations[First @ Subsets[Range @ expressions["Length"], eventInputsCountRange, {subsetIndex}]]},
    {ruleIndex, Range @ Length @ rules}
  ];
  Throw["Terminated", $$conclusionReason];
];

expressionGeneration[eventGenerations_, expressionCreatorEvents_][expression_] := ModuleScope[
  creatorEvents = Select[# <= eventGenerations["Length"] &] @ Normal @ expressionCreatorEvents["Part", expression];
  creatorEventGenerations = eventGenerations["Part", #] & /@ creatorEvents;
  Min[creatorEventGenerations]
];

spacelikeExpressionsQ[expressionDestroyerChoices_][expressions_] :=
  AllTrue[Subsets[expressions, {2}], expressionsSeparation[expressionDestroyerChoices] @@ # === "Spacelike" &];

expressionsSeparation[expressionDestroyerChoices_][firstExpression_, secondExpression_] := ModuleScope[
  If[firstExpression === secondExpression, Return["Identical", Module]];

  {firstDestroyerChoices, secondDestroyerChoices} =
    expressionDestroyerChoices["Part", #] & /@ {firstExpression, secondExpression};

  If[firstDestroyerChoices["KeyExistsQ", secondExpression] || secondDestroyerChoices["KeyExistsQ", firstExpression],
    Return["Timelike", Module]
  ];

  KeyValueMap[Function[{expression, chosenEvent},
    If[secondDestroyerChoices["KeyExistsQ", expression] && secondDestroyerChoices["Lookup", expression] =!= chosenEvent,
      Return["Branchlike", Module];
    ];
  ], Normal @ firstDestroyerChoices];
  "Spacelike"
];

declareMessage[
  General::ruleOutputError, "Messages encountered while instantiating the output for rule `rule` and inputs `inputs`."];

declareMessage[General::ruleOutputNotList, "Rule `rule` for inputs `inputs` did not generate a List."];

createEvent[rules_, ruleIndex_, matchedExpressions_, tokenDeduplication_][expressions_,
                                                                          expressionContentsToIndices_,
                                                                          eventRuleIndices_,
                                                                          eventInputs_,
                                                                          eventOutputs_,
                                                                          eventGenerations_,
                                                                          expressionCreatorEvents_,
                                                                          expressionDestroyerEventCounts_,
                                                                          expressionDestroyerChoices_,
                                                                          eventInputsHashSet_] := ModuleScope[
  ruleInputContents = expressions["Part", #] & /@ matchedExpressions;
  outputExpressions = Check[
    Replace[ruleInputContents, rules[[ruleIndex]]],
    throw[Failure[
      "ruleOutputError",
      <|"rule" -> rules[[ruleIndex]], "inputs" -> ruleInputContents|>]];
  ];
  If[!ListQ[outputExpressions],
    throw[Failure["ruleOutputNotList", <|"rule" -> rules[[ruleIndex]], "inputs" -> ruleInputContents|>]]
  ];

  eventRuleIndices["Append", ruleIndex];
  eventInputs["Append", matchedExpressions];
  eventInputsHashSet["Insert", {ruleIndex, matchedExpressions}];

  outputExpressionIndices = createExpressions[tokenDeduplication][
      expressions,
      expressionContentsToIndices,
      eventInputs,
      expressionCreatorEvents,
      expressionDestroyerEventCounts,
      expressionDestroyerChoices][
    outputExpressions, eventRuleIndices["Length"]];
  eventOutputs["Append", outputExpressionIndices];

  inputExpressionGenerations = expressionGeneration[eventGenerations, expressionCreatorEvents] /@ matchedExpressions;
  eventGenerations["Append", Max[inputExpressionGenerations, -1] + 1];

  Scan[
    expressionDestroyerEventCounts["SetPart", #, expressionDestroyerEventCounts["Part", #] + 1] &, matchedExpressions];
];

(* Finds duplicate expressions if any and returns their indices. Else, creates expressions and returns new indices. *)

createExpressions[tokenDeduplication_][
      expressions_,
      expressionContentsToIndices_,
      eventInputs_,
      expressionCreatorEvents_,
      expressionDestroyerEventCounts_,
      expressionDestroyerChoices_][
    newExpressionContents_, creatorEvent_] := ModuleScope[
  duplicateExpressionIndices = Switch[tokenDeduplication,
    None,
      Missing[],
    All,
      findDuplicateExpressions[
          expressionContentsToIndices, eventInputs, expressionDestroyerChoices][
        newExpressionContents, creatorEvent]
  ];

  If[MissingQ[duplicateExpressionIndices],
    newExpressionIndices = Range[expressions["Length"] + 1, expressions["Length"] + Length[newExpressionContents]];
    expressions["Append", #] & /@ newExpressionContents;
    MapThread[insertWholeExpressionToIndex[expressionContentsToIndices], {newExpressionIndices, newExpressionContents}];
    Do[expressionCreatorEvents["Append", CreateDataStructure["DynamicArray", {creatorEvent}]],
       Length[newExpressionContents]];
    Do[expressionDestroyerEventCounts["Append", 0], Length[newExpressionContents]];
  ,
    newExpressionIndices = duplicateExpressionIndices;
    Scan[expressionCreatorEvents["Part", #]["Append", creatorEvent] &, newExpressionIndices];
  ];

  newDestroyerChoices = CreateDataStructure["HashTable"];
  Scan[(
    newDestroyerChoices["Insert", # -> creatorEvent];
    KeyValueMap[
      Function[{expression, chosenEvent},
        newDestroyerChoices["Insert", expression -> chosenEvent];
      ],
      Normal[expressionDestroyerChoices["Part", #]]]
  ) &, eventInputs["Part", creatorEvent]];

  If[MissingQ[duplicateExpressionIndices],
    Do[expressionDestroyerChoices["Append", newDestroyerChoices["Copy"]], Length[newExpressionIndices]];
  ,
    Scan[Function[{newExpression},
      expressionDestroyerChoices["Part", newExpression]["Insert", #] & /@ Normal[Normal[newDestroyerChoices]]
    ], newExpressionIndices];
  ];

  newExpressionIndices
];

findDuplicateExpressions[expressionContentsToIndices_, eventInputs_, expressionDestroyerChoices_][
    newExpressionContents_, creatorEvent_] := ModuleScope[
  possibleDuplicates =
    Function[{newExpressionContent},
      Select[!spacelikeExpressionsQ[expressionDestroyerChoices][Append[eventInputs["Part", creatorEvent], #]] &] @
        Normal @
          expressionContentsToIndices["Lookup", newExpressionContent, {} &]
    ] /@ newExpressionContents;
  possibleMatches = Tuples @ possibleDuplicates;
  SelectFirst[sameCompatibilityWithOtherExpressions[eventInputs, expressionDestroyerChoices][#, creatorEvent] &] @
    possibleMatches
];

sameCompatibilityWithOtherExpressions[eventInputs_, expressionDestroyerChoices_][match_, creatorEvent_] := ModuleScope[
  spacelikeToCreatorEvent = Complement[
    spacelikeExpressionsToEvent[eventInputs, expressionDestroyerChoices][creatorEvent], match];
  spacelikeToMatchExpressions = Complement[#, match] & /@
    spacelikeExpressionsToExpression[expressionDestroyerChoices] /@
      match;

  AllTrue[spacelikeToMatchExpressions, SameQ[#, spacelikeToCreatorEvent] &]
];

(* TODO: Optimize this and the next functions. *)
spacelikeExpressionsToEvent[eventInputs_, expressionDestroyerChoices_][event_] := ModuleScope[
  inputs = Normal @ eventInputs["Part", event];
  allExpressions = Range @ expressionDestroyerChoices["Length"];
  Select[spacelikeExpressionsQ[expressionDestroyerChoices][Append[inputs, #]] &] @ allExpressions
];

spacelikeExpressionsToExpression[expressionDestroyerChoices_][expression_] := ModuleScope[
  allExpressions = Range @ expressionDestroyerChoices["Length"];
  Select[spacelikeExpressionsQ[expressionDestroyerChoices][{expression, #}] &] @ allExpressions
];

(* Parsing *)

$singleRulePattern = _Rule | _RuleDelayed;
parseRules[rawRules : $singleRulePattern] := {rawRules};
parseRules[rawRules : {$singleRulePattern...}] := rawRules;
declareMessage[General::invalidMultisetRules, "Rules `rules` must be a Rule, a RuleDelayed or a List of them."];
parseRules[rawRules_] := throw[Failure["invalidMultisetRules", <|"rules" -> rawRules|>]];
parseRules[rawRules___] /; !CheckArguments[MultisetSubstitutionSystem[rawRules], 1] := throw[Failure[None, <||>]];

parseTokenDeduplication[None] := None;
parseTokenDeduplication[All] := All;
declareMessage[General::tokenDeduplicationNotImplemented, "Token deduplication can only be set to None or All."];
parseTokenDeduplication[_] := throw[Failure["tokenDeduplicationNotImplemented", <||>]];

$supportedEventOrdering = {"InputCount", "SortedInputExpressions", "UnsortedInputExpressions", "RuleIndex"};
parseEventOrdering[ordering : $supportedEventOrdering] := ordering;
declareMessage[General::eventOrderingNotImplemented,
               "Only " <> $supportedEventOrdering <> " event ordering is implemented at this time."];
parseEventOrdering[_] := throw[Failure["eventOrderingNotImplemented", <||>]];

parseInit[init_List] := init;
declareMessage[General::multisetInitNotList, "Multiset Substitution System init `init` should be a List."];
parseInit[init_] := throw[Failure["multisetInitNotList", <|"init" -> init|>]];
