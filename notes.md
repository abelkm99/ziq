# Notes
---
- i want to generate a new possible set's of suggestion when a user clicks `.`.

```json
{
    "name0": "John Doe 0",
    "name1": "John Doe 1",
    "name2": "John Doe 2",
    "name3": "John Doe 3",
    "nag" : {
        "country": "",
        "state": "",
        "city": "",
        "zip code": ""
    },
    "age": 20
}
```

now on my first `.`.
 - > build my trie
    - > get the suggestions. (list of string). ["nag","age","name0","name1","name2","name3"]
    - > not let's say the person enters `.n`.
        -> go to shall i generate new suggestion the trie or mask the one that were not potential candidate.
        -> masking make so much sense. generating a list a whole lot more expensive(copies, recursion).
    -> i will have a a struct or a tuple that holds the discarded at index.
    - > for each charachter input i will have to store and track which trie i should use.


 jq . | select(.name

 - how do i know when to generate a new trie

