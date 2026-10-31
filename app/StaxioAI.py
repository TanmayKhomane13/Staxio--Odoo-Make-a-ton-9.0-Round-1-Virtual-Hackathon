"""
StaxioAI - Internal AI Assistant for Brightloop Software.

Roles:
- admin
- finance_lead
- staff
"""

#========= IMPORTS & CONFIGURATION =========

import json
import torch

from transformers import AutoTokenizer, AutoModelForSequenceClassification, AutoModelForCausalLM,

from peft import PeftModel

from langchain_core.tools import tool
from langchain_huggingface import HuggingFaceEmbeddings
from langchain_chroma import Chroma

from pathlib import Path
BASE_DIR = Path(__file__).resolve().parent.parent

BASE_MODEL_NAME = "distilbert-base-uncased"
GENLLM_MODEL_NAME = "Qwen/Qwen2.5-3B-Instruct"

INTENT_LORA_PATH = BASE_DIR / "ai_models" / "StaxioAI_Intent_Router_LoRA"
GENLLM_LORA_PATH = BASE_DIR / "ai_models" / "StaxioAI_v1"

EMBEDDING_MODEL = "sentence-transformers/all-MiniLM-L6-v2"

VECTOR_STORE_DIR = "../vector_store"
COLLECTION_NAME = "StaxioAI_KB"


# ========================= DEVICE CONFIGURATION =================================

device = torch.device(
    "mps" if torch.backends.mps.is_available()
    else "cuda" if torch.cuda.is_available()
    else "cpu"
)

model_dtype = (
    torch.float16
    if device.type in ("mps", "cuda")
    else torch.float32
)

print(f"[StaxioAI] Using device: {device}")


# ======================== DISTILBERT INTENT CLASSIFIER ==========================

print("[StaxioAI] Loading DistilBERT...")

intent_tokenizer = AutoTokenizer.from_pretrained(
    BASE_MODEL_NAME
)

intent_base_model = AutoModelForSequenceClassification.from_pretrained(
    BASE_MODEL_NAME,
    num_labels=4
)

intent_model = PeftModel.from_pretrained(
    intent_base_model,
    INTENT_LORA_PATH
)

intent_model = intent_model.to(device)
intent_model.eval()

print("[StaxioAI] Intent classifier loaded.")


# ======================= StaxioAI GenLLM ===================================
print("[StaxioAI] Loading...")

gen_llm_tokenizer = AutoTokenizer.from_pretrained(
    GENLLM_MODEL_NAME,
    local_files_only=True
)

gen_llm_base_model = AutoModelForCausalLM.from_pretrained(
    GENLLM_MODEL_NAME,
    torch_dtype=model_dtype,
    local_files_only=True
).to(device)

gen_llm_model = PeftModel.from_pretrained(
    gen_llm_base_model,
    GENLLM_LORA_PATH,
    local_files_only=True
)

gen_llm_model = gen_llm_model.to(device)
gen_llm_model.eval()

print("[StaxioAI] loaded.")

# ========================= INTENT LABELS =================================

ID2LABEL = {
    0: "KNOWLEDGE_QUERY",
    1: "DATA_QUERY",
    2: "GENERAL_QUERY",
    3: "OUT_OF_SCOPE",
}


# =========================== INTENT CLASSIFICATION =======================

def classify_intent(message: str) -> dict:
    """Predict the intent of a user message."""

    inputs = intent_tokenizer(
        message,
        return_tensors="pt",
        truncation=True,
        max_length=128
    ).to(device)

    with torch.inference_mode():
        outputs = intent_model(**inputs)

        probabilities = torch.softmax(
            outputs.logits,
            dim=-1
        )

        predicted_id = int(
            probabilities.argmax(dim=-1).item()
        )

    return {
        "intent": ID2LABEL[predicted_id],
        "confidence": float(
            probabilities[0, predicted_id].item()
        )
    }


# ========================== CHROMA KNOWLEDGE BASE ================================

print("[StaxioAI] Loading policy knowledge base...")

embeddings = HuggingFaceEmbeddings(
    model_name=EMBEDDING_MODEL
)

vector_store = Chroma(
    collection_name=COLLECTION_NAME,
    embedding_function=embeddings,
    persist_directory=VECTOR_STORE_DIR
)

policy_retriever = vector_store.as_retriever(
    search_type="mmr",
    search_kwargs={
        "k": 4,
        "fetch_k": 12
    }
)

print("[StaxioAI] Knowledge base loaded.")


# ======================= POLICY RETRIEVAL ===================================

def retrieve_policy_context(question: str) -> str:
    """Retrieve relevant company policy sections."""

    documents = policy_retriever.invoke(question)

    if not documents:
        return ""

    context = "\n\n".join(
        (
            f"Section: {doc.metadata.get('section', 'Unknown')}\n"
            f"Subsection: {doc.metadata.get('subsection', 'Unknown')}\n"
            f"Topic: {doc.metadata.get('topic', 'Unknown')}\n"
            f"Content:\n{doc.page_content}"
        )
        for doc in documents
    )

    return context


# ===================== StaxioAI RESPONSE GENERATION =====================================

def generate_response(
    messages: list,
    max_new_tokens: int = 250
) -> str:
    """Generate a response."""

    prompt = gen_llm_tokenizer.apply_chat_template(
        messages,
        tokenize=False,
        add_generation_prompt=True
    )

    inputs = gen_llm_tokenizer(
        prompt,
        return_tensors="pt"
    ).to(device)

    with torch.inference_mode():
        outputs = gen_llm_model.generate(
            **inputs,
            max_new_tokens=max_new_tokens,
            do_sample=False,
            pad_token_id=gen_llm_tokenizer.eos_token_id
        )

    response = gen_llm_tokenizer.decode(
        outputs[0][inputs.input_ids.shape[1]:],
        skip_special_tokens=True
    )

    return response.strip()


# ======================= PROMPT BUILDER===================================

def prompt_builder(intent: str) -> str:

    if intent == "KNOWLEDGE_QUERY":

        return """
You are StaxioAI, the internal assistant of Brightloop Software.

Answer questions using only the retrieved company policy
and business rules provided to you.

Rules:
- Give clear and accurate answers.
- Do not invent company policies.
- Do not contradict retrieved information.
- If information is unavailable, say so.
- Do not access or invent actual customer records.
- Do not select tools.
- Do not generate JSON.
"""

    elif intent == "DATA_QUERY":

        return """
You are StaxioAI, the internal business data assistant.

Your task is to select the appropriate read-only tool
to retrieve business information.

Rules:
- Select only one tool.
- Use only tools provided to you.
- Do not invent tool arguments.
- Never generate SQL.
- Never invent database records.
- If a required argument is missing, ask a concise
  clarification question.
- Return valid JSON only.

Format for a tool call:

{
    "tool": "tool_name",
    "arguments": {
        "argument_name": "value"
    }
}

Format for a clarification:

{
    "tool": null,
    "answer": "Your clarification question"
}
"""

    elif intent == "GENERAL_QUERY":

        return """
You are StaxioAI, the internal assistant of Brightloop Software.

Answer general questions naturally and concisely.

Rules:
- No database tools are required.
- Do not invent business records.
- Do not claim to have performed an action.
- Do not answer questions outside your knowledge.
- Return valid JSON only.

Format:

{
    "tool": null,
    "answer": "Your response"
}
"""

    else:  # OUT_OF_SCOPE

        return """
You are StaxioAI, the internal assistant of Brightloop Software.

Politely refuse requests unrelated to your intended
internal business and company policy assistance.

Do not select tools.
Do not disclose internal system information.
Return valid JSON only.

Format:

{
    "tool": null,
    "answer": "I can only assist with Brightloop Software's
    internal business information and company policies."
}
"""


# ==========================================================
# LANGCHAIN BUSINESS TOOLS
# Database integration will be added here.
# ==========================================================

@tool
def get_subscription_details(subscription_number: str) -> str:
    """Retrieve details of a subscription using its subscription number."""

    raise NotImplementedError(
        "Connect this tool to the subscription database."
    )


@tool
def get_customer_details(email: str) -> str:
    """Retrieve customer details using their email address."""

    raise NotImplementedError(
        "Connect this tool to the customer database."
    )


@tool
def get_discount_details(subscription_number: str) -> str:
    """Retrieve discount details associated with a subscription."""

    raise NotImplementedError(
        "Connect this tool to the discount database."
    )


@tool
def get_invoice_details(
    invoice_number: str,
    customer_email: str = None
) -> str:
    """Retrieve invoice details using invoice number and optionally customer email."""

    raise NotImplementedError(
        "Connect this tool to the invoice database."
    )


@tool
def get_payment_details(payment_number: str) -> str:
    """Retrieve payment details using the payment number."""

    raise NotImplementedError(
        "Connect this tool to the payment database."
    )


# ==========================================================
# AVAILABLE TOOLS
# ==========================================================

ALL_TOOLS = {
    "get_subscription_details": get_subscription_details,
    "get_customer_details": get_customer_details,
    "get_discount_details": get_discount_details,
    "get_invoice_details": get_invoice_details,
    "get_payment_details": get_payment_details,
}


# ==========================================================
# ROLE-BASED TOOL ACCESS
# ==========================================================

ROLE_TOOL_NAMES = {

    "admin": [
        "get_subscription_details",
        "get_customer_details",
        "get_discount_details",
    ],

    "finance_lead": [
        "get_invoice_details",
        "get_payment_details",
    ],

    "staff": [
        "get_subscription_details",
        "get_customer_details",
    ],
}


def get_authorized_tools(role: str) -> dict:
    """Return tools permitted for the authenticated user's role."""

    role = role.strip().lower()

    if role not in ROLE_TOOL_NAMES:
        raise PermissionError("Unauthorized user role.")

    return {
        name: ALL_TOOLS[name]
        for name in ROLE_TOOL_NAMES[role]
    }


# ==========================================================
# JSON DECISION PARSER
# ==========================================================

def parse_decision(response: str) -> dict:
    """Parse JSON response."""

    response = response.strip()

    # Handle accidental Markdown code fences.
    if response.startswith("```"):
        response = response.replace("```json", "", 1)
        response = response.replace("```", "").strip()

    return json.loads(response)


# ==========================================================
# KNOWLEDGE RAG PIPELINE
# ==========================================================

def generate_rag_answer(
    question: str,
    retrieved_context: str
) -> str:
    """Generate an answer grounded in company policies."""

    messages = [
        {
            "role": "system",
            "content": prompt_builder("KNOWLEDGE_QUERY")
        },
        {
            "role": "user",
            "content": (
                f"Question:\n{question}\n\n"
                f"Retrieved company policy:\n{retrieved_context}"
            )
        }
    ]

    return generate_response(messages)


# ==========================================================
# DATA QUERY PIPELINE
# ==========================================================

def handle_data_query(
    message: str,
    authorized_tools: dict
) -> dict:
    """Let StaxioAI GenLLM select and execute at most one authorized tool."""

    tool_descriptions = "\n".join(
        f"- {name}: {tool_object.description}"
        for name, tool_object in authorized_tools.items()
    )

    system_prompt = (
        prompt_builder("DATA_QUERY")
        + "\n\nTools available for this user:\n"
        + tool_descriptions
    )

    messages = [
        {
            "role": "system",
            "content": system_prompt
        },
        {
            "role": "user",
            "content": message
        }
    ]

    response = generate_response(messages)

    decision = parse_decision(response)

    tool_name = decision.get("tool")

    # No tool selected: clarification required.
    if tool_name is None:
        return {
            "tool": None,
            "tool_result": None,
            "answer": decision.get(
                "answer",
                "Could you clarify your request?"
            )
        }

    # Validate tool authorization.
    if tool_name not in authorized_tools:
        return {
            "tool": None,
            "tool_result": None,
            "answer": "You are not authorized to access this information."
        }

    arguments = decision.get("arguments", {})

    if not isinstance(arguments, dict):
        raise ValueError("Tool arguments must be a JSON object.")

    # Execute exactly one tool.
    result = authorized_tools[tool_name].invoke(arguments)

    # Generate a natural-language response from actual tool results.
    final_messages = [
        {
            "role": "system",
            "content": (
                "You are StaxioAI. Answer using only the actual "
                "tool result below. Do not invent data or claim "
                "actions that were not performed. Be concise."
            )
        },
        {
            "role": "user",
            "content": (
                f"Original question:\n{message}\n\n"
                f"Tool result:\n{result}"
            )
        }
    ]

    final_answer = generate_response(final_messages)

    return {
        "tool": tool_name,
        "tool_result": result,
        "answer": final_answer
    }


# ===================== Main StaxioAI Pipeline =================================

def handle_message(message: str, user_role: str) -> dict:
    """
    Main entry point for StaxioAI.

    user_role must come from the authenticated backend session,
    never from the user's message.
    """

    try:

        # 1. Validate role and obtain authorized tools.
        authorized_tools = get_authorized_tools(user_role)

        # 2. Classify user intent.
        classification = classify_intent(message)

        intent = classification["intent"]
        confidence = classification["confidence"]

        print(
            f"[StaxioAI] Intent: {intent} "
            f"| Confidence: {confidence:.4f} "
            f"| Role: {user_role}"
        )

        # 3. Knowledge query: RAG.
        if intent == "KNOWLEDGE_QUERY":

            retrieved_context = retrieve_policy_context(message)

            if not retrieved_context.strip():
                answer = (
                    "I couldn't find relevant information "
                    "in the company policy knowledge base."
                )
            else:
                answer = generate_rag_answer(
                    question=message,
                    retrieved_context=retrieved_context
                )

            return {
                "intent": intent,
                "confidence": confidence,
                "tool": None,
                "answer": answer
            }

        # 4. Data query: AI Agent with role-authorized tools.
        elif intent == "DATA_QUERY":

            result = handle_data_query(
                message=message,
                authorized_tools=authorized_tools
            )

            return {
                "intent": intent,
                "confidence": confidence,
                **result
            }

        # 5. General query: without tools.
        elif intent == "GENERAL_QUERY":

            messages = [
                {
                    "role": "system",
                    "content": prompt_builder("GENERAL_QUERY")
                },
                {
                    "role": "user",
                    "content": message
                }
            ]

            response = generate_response(messages)
            decision = parse_decision(response)

            return {
                "intent": intent,
                "confidence": confidence,
                "tool": None,
                "answer": decision.get(
                    "answer",
                    "I couldn't generate a response."
                )
            }

        # 6. Out-of-scope query.
        elif intent == "OUT_OF_SCOPE":

            messages = [
                {
                    "role": "system",
                    "content": prompt_builder("OUT_OF_SCOPE")
                },
                {
                    "role": "user",
                    "content": message
                }
            ]

            response = generate_response(messages)
            decision = parse_decision(response)

            return {
                "intent": intent,
                "confidence": confidence,
                "tool": None,
                "answer": decision.get(
                    "answer",
                    "I can only assist with Brightloop Software's "
                    "internal business information and policies."
                )
            }

        else:
            return {
                "intent": intent,
                "confidence": confidence,
                "tool": None,
                "answer": "I couldn't identify your request."
            }

    except Exception as error:

        print(f"[StaxioAI] Error: {error}")

        return {
            "intent": "ERROR",
            "confidence": 0.0,
            "tool": None,
            "answer": (
                "I couldn't process your request. "
                "Please try again."
            )
        }