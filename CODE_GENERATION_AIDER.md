# Code Generation Process - Aider

## Overview

This document describes the end-to-end workflow from user prompt to generated code implementation in the Aider project. The process is orchestrated through the `Coder` class hierarchy, which coordinates session management, coder selection, prompt construction, LLM interaction, and response processing.

## What is a "Coder"?

A **Coder** in Aider is best understood as an **agent-like orchestrator** that manages the entire code generation workflow. It sits between a pure "agent" (which typically has broader capabilities and tool selection) and a "tool" (which performs a single function).

### Coder as Orchestrator

A Coder is a full-featured orchestrator that:

1. **Manages Session State**: 
   - Tracks conversation history (`done_messages`, `cur_messages`)
   - Manages file lists (`abs_fnames`, `abs_read_only_fnames`)
   - Tracks edited files (`aider_edited_files`)
   - Maintains git commit hashes and costs

2. **Constructs Prompts**:
   - Builds system prompts with format-specific instructions
   - Includes file contents, repo map, and conversation history
   - Manages token budgets and context limits

3. **Interacts with LLMs**:
   - Sends prompts via `Model.send_completion()`
   - Handles streaming and non-streaming responses
   - Processes function calls (for function-based coders)
   - Extracts reasoning content if present

4. **Parses and Applies Edits**:
   - Parses edit format-specific syntax (SEARCH/REPLACE, whole file, diff, etc.)
   - Validates edits before application
   - Applies edits to files
   - Handles errors and malformed responses

5. **Post-Processing**:
   - Runs auto-lint on edited files
   - Runs auto-test if configured
   - Implements reflection loop for error recovery
   - Detects file mentions and prompts for addition

### Coder vs Agent vs Tool

- **Compared to Agents**: Coders are more specialized and format-centric. They don't have a tool registry or dynamic tool selection. Instead, each coder specializes in a specific edit format (SEARCH/REPLACE, whole file, diff, etc.). However, like agents, they orchestrate the entire workflow from prompt to code application.

- **Compared to Tools**: Coders are much more than tools. A tool typically performs a single function (e.g., "edit file", "read file"). A coder is a complete workflow orchestrator that manages state, constructs prompts, interacts with LLMs, and applies edits. Tools are passive functions; coders are active orchestrators.

- **Something In Between**: Coders are **specialized orchestrators** - they have the breadth of responsibility of an agent but are specialized for a specific edit format. They're format-centric rather than capability-centric.

## High-Level Flow

1. **User Input**: User provides a message via CLI (`main.py`) or programmatic API
2. **Coder Creation**: A `Coder` instance is created via `Coder.create()` based on edit format and model
3. **Message Processing**: User message is processed via `preproc_user_input()` which handles commands, file mentions, and URLs
4. **Prompt Construction**: Prompt is built via `format_messages()` which assembles system prompts, file content, repo map, and conversation history
5. **LLM Interaction**: Prompt is sent to LLM via `Model.send_completion()` using LiteLLM
6. **Response Processing**: Stream is processed via `send()` which handles text, function calls, and reasoning content
7. **Edit Application**: Edits are extracted and applied via `apply_updates()` using coder-specific parsers
8. **Post-Processing**: Auto-lint, auto-test, and reflection loops may trigger additional iterations
9. **History Management**: Messages are moved to `done_messages` and optionally summarized

## Detailed Component Flow

### 1. Coder Selection and Initialization

The `Coder` class is the central component that handles code generation. Different coders implement different edit formats. The coder is selected once at session start (or when switching modes) and persists for the entire session unless explicitly changed.

#### 1.1 Coder Types

Coders are selected based on `edit_format` parameter:

- **EditBlockCoder** (`editblock`): Uses SEARCH/REPLACE blocks for incremental edits
- **EditBlockFencedCoder** (`editblock-fenced`): Similar to editblock but with fenced code blocks
- **WholeFileCoder** (`whole`): Returns complete file contents
- **PatchCoder** (`patch`): Uses V4A diff format with `*** Begin Patch` / `*** End Patch` markers
- **UnifiedDiffCoder** (`udiff`): Uses unified diff format
- **UnifiedDiffSimpleCoder** (`udiff-simple`): Simplified unified diff format
- **AskCoder** (`ask`): Read-only mode, no file edits
- **ArchitectCoder** (`architect`): Two-stage process with architect model proposing changes and editor model implementing them
- **ContextCoder** (`context`): Identifies which files need editing
- **HelpCoder** (`help`): Provides help about Aider usage
- **Function-based coders**: Use LLM function calling API (e.g., `EditBlockFunctionCoder`, `WholeFileFunctionCoder`)

#### 1.2 Coder Creation (`Coder.create`)

Coder selection follows this process:

1. **Edit Format Resolution** (priority order):
   - If `edit_format` is explicitly provided (via CLI `--edit-format` or command), use it
   - Special case: If `edit_format == "code"`, treat as `None` (use model default)
   - If `edit_format is None`:
     - If `from_coder` exists (switching from another coder), use `from_coder.edit_format`
     - Otherwise, use `main_model.edit_format` (model's default edit format)
   - Model defaults are defined in `ModelSettings` class (default: `"whole"`) and can be overridden:
     - In `model-settings.yml` resource file
     - In model-specific configuration via `configure_model_settings()` method
     - Examples: Claude models default to `"diff"`, some models use `"editblock"`

2. **Coder Class Selection**: 
   - Iterates through `coders.__all__` (all registered coder classes)
   - Finds first coder class where `coder.edit_format == edit_format`
   - Instantiates the matching coder class with provided parameters
   - Raises `UnknownEditFormat` exception if no match found (lists valid formats)

3. **Context Transfer** (if `from_coder` provided):
   - Transfers conversation history: `done_messages`, `cur_messages`
   - Transfers file lists: `abs_fnames`, `abs_read_only_fnames`
   - Transfers state: `aider_commit_hashes`, `total_cost`, `ignore_mentions`, etc.
   - Transfers commands, file watcher, token counts
   - **History Summarization**: If edit format changes, old assistant messages may confuse new LLM, so:
     - If `edit_format != from_coder.edit_format` and `summarize_from_coder=True`:
       - Summarizes `done_messages` using `summarizer.summarize_all()`
       - Preserves important context while removing format-specific examples

4. **Initialization**: 
   - Sets up repository (`GitRepo`), file tracking, repo map (`RepoMap`), summarizer (`ChatSummary`), linter (`Linter`)
   - Configures model-specific settings (streaming, cache, reasoning tags)
   - Stores original kwargs for potential future cloning/switching

#### 1.3 When Coders Are Selected

Coders are selected at these points:

1. **Session Start** (`main.py`):
   - When Aider starts, `Coder.create()` is called with:
     - `edit_format` from CLI `--edit-format` argument (or `None`)
     - `main_model` from CLI `--model` argument
   - If no `edit_format` specified, uses model's default

2. **Mode Switching** (via commands):
   - `/ask` command: Creates `AskCoder` (read-only mode)
   - `/code` command: Switches back to edit mode using model's default format
   - `/chat-mode` command: Switches to specified edit format
   - `/model` command: May switch coder if new model has different default format
   - Uses `SwitchCoder` exception to trigger coder recreation

3. **Architect Workflow**:
   - `ArchitectCoder` creates a new `EditorCoder` after architect proposal is accepted
   - Editor coder uses `editor_model` and `editor_edit_format` from main model

4. **Context Coder Workflow**:
   - `ContextCoder` identifies files, then reflects with a new coder to perform edits

#### 1.4 Coder Registration

All available coders are registered in `aider/coders/__init__.py`:

- Coders are imported and added to `__all__` list
- Each coder class must have an `edit_format` class attribute
- `Coder.create()` iterates through `coders.__all__` to find matching coder
- New coders can be added by:
  1. Creating a new coder class inheriting from `Coder`
  2. Setting `edit_format` class attribute
  3. Adding to `__all__` in `__init__.py`

### 2. Prompt Construction

The LLM prompt is constructed in `Coder.format_messages()` through several steps:

#### 2.1 System Prompt Construction (`format_chat_chunks`)

The system prompt is built from multiple components:

1. **Main System Prompt** (`gpt_prompts.main_system`):
   - Coder-specific prompt (e.g., `EditBlockPrompts.main_system`)
   - Formatted via `fmt_system_prompt()` which includes:
     - Fence selection (triple/quadruple backticks, XML tags)
     - Platform information (OS, shell, language, date, git status)
     - Shell command prompts (if enabled)
     - Language preferences
     - Model-specific reminders (lazy, overeager)

2. **Example Messages** (`gpt_prompts.example_messages`):
   - Can be included in system prompt (`examples_as_sys_msg=True`) or as separate messages
   - Demonstrates expected edit format

3. **System Reminder** (`gpt_prompts.system_reminder`):
   - Detailed format instructions (e.g., SEARCH/REPLACE block rules)
   - Can be placed in system message or appended to user message
   - Only included if token budget allows

#### 2.2 File Content Inclusion

Files are included in the prompt through several message groups:

1. **Chat Files** (`get_chat_files_messages`):
   - Files explicitly added to chat (`abs_fnames`)
   - Full file contents with fence markers
   - Prefix: "I have *added these files to the chat* so you can go ahead and edit them"
   - If no files added but repo map exists: "Don't try and edit any existing code without asking me to add the files to the chat!"

2. **Read-Only Files** (`get_readonly_files_messages`):
   - Files provided for reference (`abs_read_only_fnames`)
   - Prefix: "Here are some READ ONLY files, provided for your reference"
   - Includes images/PDFs if model supports vision

3. **Repo Map** (`get_repo_messages`):
   - Summaries of repository files (via `RepoMap.get_repo_map()`)
   - Includes file structure and key symbols (classes, functions)
   - Ranked by relevance to current message (mentioned files, identifiers)
   - Prefix: "Here are summaries of some files present in my git repository. Do not propose changes to these files"

#### 2.3 Conversation History

History is managed in two parts:

1. **Done Messages** (`done_messages`):
   - Completed conversation turns
   - Can be summarized if too large (`ChatSummary.summarize()`)
   - Summarization runs in background thread

2. **Current Messages** (`cur_messages`):
   - Active conversation turn
   - Includes user message and assistant response
   - Moved to `done_messages` after completion

#### 2.4 Message Assembly (`ChatChunks`)

Messages are assembled in this order:

1. **System messages**: Main system prompt (or user/assistant pair if model doesn't support system role)
2. **Example messages**: Format demonstrations
3. **Read-only files**: Reference files
4. **Repo map**: Repository context
5. **Done messages**: Conversation history
6. **Chat files**: Files available for editing
7. **Current messages**: Current user message and assistant response
8. **Reminder**: System reminder (if space allows)

#### 2.5 Token Management

- Token counting via `Model.token_count()` before sending
- Warnings if approaching context limits
- Reminder prompt only included if token budget allows
- Cache control headers added for prompt caching (if enabled)

### 3. Tool/Function Selection and Incorporation

Aider uses two approaches for tool/function integration:

#### 3.1 Function-Based Coders

Some coders use LLM function calling API:

1. **Function Definition**:
   - Coders define `functions` attribute with JSON Schema
   - Example: `EditBlockFunctionCoder` defines `replace_lines` function
   - Example: `WholeFileFunctionCoder` defines `write_files` function

2. **Function Schema**:
   - Validated via `jsonschema.Draft7Validator` during initialization
   - Passed to LLM via `Model.send_completion(functions=...)`

3. **Function Call Processing**:
   - Function calls captured in `partial_response_function_call`
   - Arguments parsed via `parse_partial_args()` (handles incomplete JSON)
   - Executed via coder-specific `_update_files()` method
   - Results not sent back to LLM (unlike tool-calling frameworks)

#### 3.2 Text-Based Edit Formats

Most coders use text-based edit formats (no function calling):

- **EditBlock**: SEARCH/REPLACE blocks in markdown
- **WholeFile**: Complete file contents in fenced blocks
- **Patch**: V4A diff format
- **UnifiedDiff**: Standard diff format

These are parsed from LLM text responses, not function calls.

#### 3.3 No External Tools

Unlike OpenCode, Aider does not use:
- External tool registries
- MCP (Model Context Protocol) integration
- Plugin systems for tools
- Tool execution results fed back to LLM

Instead, edits are parsed from text responses and applied directly.

### 4. LLM Interaction

The prompt is sent to the LLM through the `Model` class using LiteLLM.

#### 4.1 Model Resolution

Model selection:
1. Explicit `--model` argument
2. Default model selection via `select_default_model()` (checks API keys, offers OAuth)
3. Model metadata loaded from `.aider.model.metadata.json` files

#### 4.2 Request Configuration

`Model.send_completion()` configures:
- `model`: Model name
- `messages`: Formatted message list
- `functions`: Function schemas (if function-based coder)
- `stream`: Streaming enabled/disabled
- `temperature`: From model settings or coder override
- `extra_params`: Model-specific parameters

#### 4.3 Streaming vs Non-Streaming

- **Streaming**: Response chunks processed incrementally via `show_send_output_stream()`
- **Non-Streaming**: Full response processed at once via `show_send_output()`
- Reasoning content (thinking tokens) extracted separately if present

### 5. Response Processing

LLM responses are processed via `Coder.send()` and `send_message()`.

#### 5.1 Stream Processing

The processor handles these stream events:

- **Text chunks**: Accumulated in `partial_response_content`
- **Function calls**: Captured in `partial_response_function_call`
- **Reasoning content**: Extracted and removed (if `reasoning_tag` configured)
- **Finish reasons**: Handled (length, stop, etc.)

#### 5.2 Edit Extraction

After response completes, edits are extracted:

1. **Function-Based**: 
   - `parse_partial_args()` extracts function arguments
   - `_update_files()` applies edits

2. **Text-Based**:
   - `get_edits()` parses edit format (coder-specific)
   - Returns list of `(path, original, updated)` or `(path, content)` tuples

#### 5.3 Edit Application

Edits are applied via `apply_updates()`:

1. **Dry Run** (`apply_edits_dry_run`): Validates edits without applying
2. **Preparation** (`prepare_to_edit`): Checks file permissions, validates paths
3. **Application** (`apply_edits`): 
   - Reads file content
   - Applies edits (search/replace, whole file, patch, etc.)
   - Writes updated content
   - Tracks edited files

#### 5.4 Error Handling

- **Malformed responses**: `ValueError` caught, error message stored in `reflected_message`
- **Git errors**: Caught and reported
- **File errors**: Reported, edits skipped
- **Permission errors**: Files not in chat are skipped

### 6. Post-Processing and Iteration

After edits are applied, several post-processing steps may occur:

#### 6.1 Auto-Lint

If `auto_lint=True`:
1. `lint_edited()` runs linter on edited files
2. If errors found, user asked: "Attempt to fix lint errors?"
3. If yes, lint errors added to `reflected_message` for next iteration

#### 6.2 Auto-Test

If `auto_test=True`:
1. `cmd_test()` runs test command
2. If failures, user asked: "Attempt to fix test errors?"
3. If yes, test errors added to `reflected_message` for next iteration

#### 6.3 Shell Commands

If LLM response contains shell commands (detected via prompts):
1. Commands extracted and executed
2. Output optionally added to conversation

#### 6.4 Reflection Loop

The `run_one()` method implements a reflection loop:

1. Process user message
2. If `reflected_message` is set:
   - Increment `num_reflections`
   - If under `max_reflections` (default 3), process `reflected_message` as new user message
   - Continue until no reflection or max reached

Reflection is triggered by:
- Lint errors (if auto-lint enabled)
- Test failures (if auto-test enabled)
- Malformed response errors
- Context coder file identification

#### 6.5 File Mention Detection

After response, `check_for_file_mentions()`:
1. Scans response text for file paths
2. Prompts user to add mentioned files to chat
3. Adds files if confirmed

### 7. History Management

#### 7.1 Message Storage

Messages are stored in:
- `cur_messages`: Current conversation turn
- `done_messages`: Completed turns

#### 7.2 History Summarization

If `ChatSummary.too_big()`:
1. Background thread starts summarization
2. Uses weak model (or main model) to summarize
3. Replaces `done_messages` with summary
4. Preserves important context (file changes, tool results)

#### 7.3 History Persistence

- Chat history saved to `.aider.chat.history.md`
- Restored on startup if `--restore-chat-history` enabled
- Markdown format with user/assistant messages

### 8. Special Coders

#### 8.1 ArchitectCoder

Two-stage process:
1. **Architect stage**: Uses `AskCoder` to propose changes (no edits)
2. **Editor stage**: Uses editor model with appropriate edit format to implement changes
3. User can accept/reject architect proposal
4. Editor applies changes if accepted

#### 8.2 ContextCoder

File identification mode:
1. Analyzes user request
2. Identifies files that need editing (via repo map and mentions)
3. Adds files to chat
4. Reflects with "try again" message to proceed with edits

#### 8.3 AskCoder

Read-only mode:
- No file edits allowed
- Used for questions and discussions
- Can switch to edit mode via `/code` command

### 9. Repo Map System

The `RepoMap` class provides repository context:

#### 9.1 Repo Map Generation

1. **File Ranking**: 
   - Files ranked by relevance to current message
   - Considers: mentioned files, mentioned identifiers, files in chat
   - Uses ctags to extract symbols (classes, functions)

2. **Content Selection**:
   - Selects top-ranked files up to `max_map_tokens`
   - Includes key symbols and their definitions
   - Shows file structure and relationships

3. **Caching**:
   - Tags cached in `.aider.tags.cache.v*`
   - Map cached per message context
   - Refresh modes: "auto", "always", "files"

#### 9.2 Repo Map Usage

- Included in prompt as read-only context
- Helps LLM understand codebase structure
- Enables file discovery without full file contents
- Reduces token usage vs including all files

### 10. Core Components

- **Coder** (`base_coder.py`): Main code generation orchestrator
- **Model** (`models.py`): LLM interaction and configuration
- **RepoMap** (`repomap.py`): Repository context generation
- **GitRepo** (`repo.py`): Git integration and commit management
- **Commands** (`commands.py`): User command processing
- **InputOutput** (`io.py`): User interaction and I/O
- **ChatSummary** (`history.py`): Conversation summarization
- **Linter** (`linter.py`): Code linting integration

## Key Implementation Details

### Edit Format Parsing

Each coder implements format-specific parsing:

- **EditBlock**: Parses `<<<<<<< SEARCH` / `=======` / `>>>>>>> REPLACE` blocks
- **WholeFile**: Parses fenced code blocks with filenames
- **Patch**: Parses V4A diff format with `*** [ACTION] File:` markers
- **UnifiedDiff**: Parses standard unified diff format
- **Function**: Extracts JSON from function call arguments

### Fence Selection

Coders automatically select fence markers (backticks, XML tags) that don't conflict with file content:
- Tries multiple fence options
- Selects first that doesn't appear in file content
- Falls back to triple backticks if all conflict

### File Tracking

- `abs_fnames`: Absolute paths of files in chat (editable)
- `abs_read_only_fnames`: Absolute paths of read-only files
- `aider_edited_files`: Files edited by Aider (tracked for commits)
- Files tracked relative to repo root or common root

### Commit Management

If `auto_commits=True`:
- Commits created after edits with descriptive messages
- Uses LLM to generate commit messages (if commit model configured)
- Tracks commit hashes in `aider_commit_hashes`
- Can attribute commits to Aider or user

## Differences from OpenCode

This section compares Aider's approach with OpenCode (as described in `CODE_GENERATION_PROCESS_V2.md`).

### Architecture

1. **Coder-Based vs Session-Based**:
   - Aider uses `Coder` classes for different edit formats
   - OpenCode uses `SessionPrompt` with agent/tool selection
   - Aider's coders are more specialized (format-specific)
   - OpenCode's agents are more general (capability-based)

2. **Edit Formats vs Tools**:
   - Aider uses text-based edit formats (SEARCH/REPLACE, whole file, diff)
   - OpenCode uses tool-based approach (edit, read, write tools)
   - Aider's edits are embedded in LLM responses
   - OpenCode's edits are tool calls with results fed back

3. **Function Calling**:
   - Aider has optional function-based coders (limited use)
   - OpenCode uses extensive function/tool calling with iterative execution
   - Aider's functions don't return results to LLM
   - OpenCode's tools return results for continued conversation

### Prompt Construction

1. **System Prompt**:
   - Aider: Coder-specific prompts with format instructions
   - OpenCode: Agent-specific prompts with tool descriptions
   - Aider includes format examples in system prompt
   - OpenCode includes tool schemas in system prompt

2. **File Inclusion**:
   - Aider: Files included as full content in fenced blocks
   - OpenCode: Files included via `file://` URLs with LSP symbol resolution
   - Aider uses repo map for repository overview
   - OpenCode uses LSP for precise symbol extraction

3. **Context Management**:
   - Aider: Repo map provides repository structure
   - OpenCode: LSP provides code analysis and symbol resolution
   - Aider summarizes conversation history
   - OpenCode compacts sessions when context overflows

### Response Processing

1. **Edit Application**:
   - Aider: Parses edits from text, applies immediately
   - OpenCode: Tool calls executed, results returned to LLM
   - Aider: Single-pass edit application
   - OpenCode: Iterative tool execution loop

2. **Error Handling**:
   - Aider: Errors trigger reflection loop with error message
   - OpenCode: Errors stored in tool parts, loop continues
   - Aider: User confirmation for retries
   - OpenCode: Automatic retry with error context

3. **Iteration**:
   - Aider: Reflection loop for lint/test errors
   - OpenCode: Tool call loop until `finishReason !== "tool-calls"`
   - Aider: Limited reflections (max 3)
   - OpenCode: Continues until completion or error

### Tool/Function System

1. **Tool Selection**:
   - Aider: No tool registry, edits embedded in responses
   - OpenCode: Tool registry with MCP integration
   - Aider: Format-specific coders
   - OpenCode: Tool-based agents

2. **Permission System**:
   - Aider: Files must be explicitly added to chat
   - OpenCode: Permission system with user approval
   - Aider: Read-only files separate from editable files
   - OpenCode: Permission checks before tool execution

3. **Plugin System**:
   - Aider: No plugin system
   - OpenCode: Plugin system with hooks for customization

### Session Management

1. **State Storage**:
   - Aider: In-memory with optional history file
   - OpenCode: Persistent session storage
   - Aider: Simple message list
   - OpenCode: Structured message parts (text, tool, reasoning, patch)

2. **Session Compaction**:
   - Aider: Background summarization thread
   - OpenCode: Explicit compaction before each request
   - Aider: Summarizes when history too large
   - OpenCode: Compacts when approaching context limit

### Agent/Subagent System

1. **Agent Selection**:
   - Aider: Coder selection based on edit format
   - OpenCode: Agent selection based on capabilities
   - Aider: Single coder per session
   - OpenCode: Multiple agents with subagent execution

2. **Subagent Execution**:
   - Aider: ArchitectCoder uses two-stage process (architect + editor)
   - OpenCode: Task tool creates child sessions with subagents
   - Aider: Architect proposal must be accepted
   - OpenCode: Subagent results automatically aggregated

## Summary

### Nature of Coders

**Coders are specialized orchestrators** that sit between agents and tools:

- **Like Agents**: They orchestrate the entire workflow (prompt construction, LLM interaction, edit application, post-processing). They manage session state and have broad responsibilities.

- **Unlike Agents**: They are format-centric rather than capability-centric. Each coder specializes in a specific edit format (SEARCH/REPLACE, whole file, diff, etc.) rather than having dynamic tool selection. They don't use a tool registry or plugin system.

- **Unlike Tools**: They are active orchestrators, not passive functions. A tool performs a single operation; a coder manages the entire code generation workflow from user input to file edits.

- **Specialization**: Each coder has its own prompt templates, edit format parsers, and format-specific instructions. This specialization makes them more focused and efficient for their specific edit format.

### Coder Selection Summary

Coders are selected based on `edit_format` with this priority:
1. Explicit `--edit-format` argument (highest priority)
2. Current coder's format (when switching modes)
3. Model's default `edit_format` (lowest priority, fallback)

Selection happens via `Coder.create()` which:
- Resolves `edit_format` using priority above
- Searches `coders.__all__` for matching coder class
- Instantiates the coder with context from previous coder (if switching)
- Raises `UnknownEditFormat` if no match found

### Overall Architecture

Aider takes a **format-centric approach** where different coders specialize in different edit formats (SEARCH/REPLACE, whole file, diff, etc.). Edits are embedded in LLM text responses and parsed after completion. The system uses a reflection loop for error recovery and includes repository context via a repo map system.

OpenCode takes a **tool-centric approach** where agents use tools (edit, read, write, etc.) via function calling. Tool results are fed back to the LLM for iterative execution. The system uses LSP for code analysis and has a more structured session management system with plugins and permissions.

Both approaches have strengths: Aider's format-based approach is simpler and more direct, while OpenCode's tool-based approach is more flexible and extensible.

