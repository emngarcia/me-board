import os
import time
from typing import List, Tuple

from dotenv import load_dotenv
from supabase import create_client

import torch
from transformers import AutoTokenizer, AutoModelForSequenceClassification

load_dotenv()

# -----------------------
# Env / config
# -----------------------
SUPABASE_URL = os.environ["SUPABASE_URL"]
SUPABASE_SERVICE_ROLE_KEY = os.environ["SUPABASE_SERVICE_ROLE_KEY"]  # server-side only

# If your model is private, HF_TOKEN must be set OR you must `huggingface-cli login`.
HF_MODEL = os.getenv("HF_MODEL", "emngarcia/deberta_mh_benign_worrisome")

MODEL_VERSION = os.getenv("MODEL_VERSION", "hackathon-v1")
BATCH_SIZE = int(os.getenv("BATCH_SIZE", "5"))
SLEEP_SECONDS = float(os.getenv("SLEEP_SECONDS", "1.0"))
MAX_LEN = int(os.getenv("MAX_LEN", "256"))

# -----------------------
# Clients
# -----------------------
sb = create_client(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY)

# -----------------------
# Load model locally (once)
# -----------------------
# Force slow tokenizer to avoid the fast-tokenizer crash you saw.
tokenizer = AutoTokenizer.from_pretrained(HF_MODEL, use_fast=False)
model = AutoModelForSequenceClassification.from_pretrained(HF_MODEL)
model.eval()

# Optional: put model on GPU if available (not typical on Mac)
device = torch.device("cuda") if torch.cuda.is_available() else torch.device("cpu")
model.to(device)

def infer_batch(texts: List[str]) -> List[Tuple[float, str]]:
    """
    Returns list of (score, label) for each text.
    score = max softmax prob, label = argmax id2label
    """
    enc = tokenizer(
        texts,
        truncation=True,
        max_length=MAX_LEN,
        padding=True,
        return_tensors="pt",
    )
    enc = {k: v.to(device) for k, v in enc.items()}

    with torch.no_grad():
        logits = model(**enc).logits
        probs = torch.softmax(logits, dim=-1)

    scores, ids = torch.max(probs, dim=-1)

    out: List[Tuple[float, str]] = []
    for s, i in zip(scores.tolist(), ids.tolist()):
        label = model.config.id2label.get(int(i), str(int(i)))
        out.append((float(s), label))
    return out

def mark_failed(event_id: str, err: Exception) -> None:
    # You can also store err text if you added an `error` column.
    sb.table("keyboard_events").update({"status": "failed"}).eq("id", event_id).execute()
    print("FAILED", event_id, err)

def main() -> None:
    print(f"Worker started. Model={HF_MODEL} device={device} batch={BATCH_SIZE}")

    while True:
        claimed = sb.rpc("claim_keyboard_events", {"batch_size": BATCH_SIZE}).execute().data or []
        if not claimed:
            time.sleep(SLEEP_SECONDS)
            continue

        # batch inference
        event_ids = [row["id"] for row in claimed]
        texts = [row["text"] for row in claimed]

        try:
            preds = infer_batch(texts)
        except Exception as e:
            # If model inference fails, mark all claimed as failed
            for eid in event_ids:
                mark_failed(eid, e)
            continue

        # write results row-by-row (simple + reliable for hackathon)
        for eid, (score, label) in zip(event_ids, preds):
            try:
                sb.table("predictions").upsert(
                    {
                        "event_id": eid,
                        "label": label,
                        "score": score,
                        "model_version": MODEL_VERSION,
                    },
                    on_conflict="event_id",
                ).execute()

                sb.table("keyboard_events").update({"status": "done"}).eq("id", eid).execute()

            except Exception as e:
                mark_failed(eid, e)

if __name__ == "__main__":
    main()
