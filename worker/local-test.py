from transformers import AutoTokenizer, AutoModelForSequenceClassification
import torch

MODEL_ID = "emngarcia/deberta_mh_benign_worrisome"

tokenizer = AutoTokenizer.from_pretrained(MODEL_ID, use_fast=False)
model = AutoModelForSequenceClassification.from_pretrained(MODEL_ID)
model.eval()

text = "I feel fine today."
enc = tokenizer(text, return_tensors="pt", truncation=True, max_length=256)

with torch.no_grad():
    logits = model(**enc).logits
    probs = torch.softmax(logits, dim=-1)[0]

score = float(probs.max())
pred_id = int(probs.argmax())
label = model.config.id2label.get(pred_id, str(pred_id))

print({"label": label, "score": score})
