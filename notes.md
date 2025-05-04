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
    -> I will have a a struct or a tuple that holds the discarded at index. (struct is more clear and straight forward in this case)
    -> for each charachter input i will have to store and track which trie i should use.


 jq . | select(.name)

 // whenever the user clicks . i shall generate a new trie
 // [I should also create a parser to get the `| keys`]


 - how do i know when to generate a new trie and what shall i do with the previous one ?

 when the user types `.`
    - > check if the error_buffer is empty. if so just stop right here
    - > run a jq process on the response.
        -> parse and populate the trie.
    - > use thread to do this thing in the background.
