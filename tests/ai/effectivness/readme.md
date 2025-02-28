The test uses chat gpt to check similarity between queries and founded most similar post.
- queries.sql contains the sql code
- test.prompt contains prompt for chat-gpt
- test.sh generate a json document that needs to be attached to the prompt in chat-gpt

### Steps
1. synchronize posts
2. start ./test.sh > out.json
3. attach out.json to chat-gpt with a prompt from test.prompt