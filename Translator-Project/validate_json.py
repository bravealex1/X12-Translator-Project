import json

filename = "Example.json"  

try:
    with open(filename, "r", encoding="utf-8") as f:
        json.load(f)
    print(" Τhe JSON is ok!")
except json.JSONDecodeError as e:
    print(" Error JSON:")
    print(e)
