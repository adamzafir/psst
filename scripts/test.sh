#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
# No XCTest/Xcode dependency: exercise the exact routing code used by the tap.
swiftc Sources/Psst/ShortcutRouting.swift Tests/ShortcutRoutingTests.swift -o .build/shortcut-tests
.build/shortcut-tests
swiftc Sources/Psst/QuestionKey.swift Tests/QuestionKeyTests.swift -o .build/question-key-tests
.build/question-key-tests
swiftc -parse-as-library -target "$(uname -m)-apple-macosx26.0" Sources/Psst/AnswerEngine.swift Sources/Psst/QuestionKey.swift Sources/Psst/SpeechCapture.swift Sources/Psst/FastSpeech.swift Tests/AnswerRunTests.swift -o .build/answer-run-tests
.build/answer-run-tests
swiftc -parse-as-library Sources/Psst/AnswerFormatting.swift Tests/AnswerFormattingTests.swift -o .build/formatting-tests
.build/formatting-tests
