# NOTE: To enable debugging from Visual Studio Code, make sure you use the following command to install the aider:
# `pip install -e . --no-deps --force-reinstall`
export OLLAMA_API_BASE=http://127.0.0.1:11434
aider --model ollama_chat/qwen3-coder:30b-a3b-q8_0
