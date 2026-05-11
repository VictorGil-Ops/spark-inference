import asyncio
import time
import json
from openai import AsyncOpenAI

# Configuration of the client (adjust the port if necessary)
client = AsyncOpenAI(
    base_url="http://localhost:8200/v1", 
    api_key= "sk-no-token"
)

TEST_CASES = [
    {
        "name": "Spatial Logic (Cinema Row)",
        "prompt": "Five people (A, B, C, D, E) are sitting in a row. A cannot be next to B. C must be directly to the right of D. E is at one of the ends of the row. If B is in position 2, what are the possible positions for everyone else? Reason step-by-step before providing the final arrangements."
    },
    {
        "name": "Theory of Mind (The Diamond)",
        "prompt": "Marta puts a diamond in a red box and leaves the room. While she is away, Juan moves the diamond to a blue box and then paints the original red box green. Marta returns. Where will she look for the diamond, and what color does she believe the box she left it in is? Explain why."
    },
    {
        "name": "Security & Causal Reasoning (Attack Chain)",
        "prompt": "Server A only accepts traffic from Server B. Server B has a Remote Code Execution (RCE) vulnerability, but it is only exploitable via a serial console connection. An attacker compromises the laptop of the IT administrator, who has active serial console access to Server B. Map out the logical attack chain to reach Server A and identify the 'weakest link' in this architecture based strictly on the provided conditions."
    },
    {
        "name": "Linguistic Mathematics (The Scalability Trap)",
        "prompt": "If it takes three programmers three hours to patch three servers, how many minutes would it take one hundred programmers to patch one hundred servers if they all work in parallel on separate servers? Explain your math."
    }
]

async def run_test(case):
    print(f"\n🚀 Executing: {case['name']}")
    start_time = time.perf_counter()

    # Check models and change model= if necessary to match the log output
    # curl http://localhost:8200/v1/models (change port if necessary)
    response = await client.chat.completions.create(
        model="nvidia/Gemma-4-26B-A4B-NVFP4",  # Changed to match the log
        messages=[{"role": "user", "content": case['prompt']}],
        temperature=0, # Deterministic for debug
        max_tokens=1024,
        stream=False
    )
    
    end_time = time.perf_counter()
    duration = end_time - start_time
    
    text = response.choices[0].message.content
    tokens = response.usage.completion_tokens
    tps = tokens / duration

    print(f"⏱️ Latency total: {duration:.2f}s")
    print(f"📊 Throughput: {tps:.2f} tokens/s")
    print(f"📝 Response:\n{'-'*20}\n{text}\n{'-'*20}")

async def main():
    for case in TEST_CASES:
        await run_test(case)

if __name__ == "__main__":
    asyncio.run(main())