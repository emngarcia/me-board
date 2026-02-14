from flask import Flask, request, jsonify

app = Flask(__name__)

@app.post("/analyze-entry")
def analyze_entry():
    data = request.get_json()
    text = data.get("text", "")

    # Replace this with your model call
    result = {
        "summary": text[:100],
        "length": len(text)
    }

    return jsonify(result)

@app.get("/")
def health():
    return "OK"


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000, debug=True)
