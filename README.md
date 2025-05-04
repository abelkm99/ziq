# TODO
 - [ ] process the result for the new command.



## Immediate Bug fixes.
- [x] when the error window is maximized it's not using 100% of the available width.
- [x] Broken Pipe BUG when passing sizes more than 64kb with invalid command.
    - had something to do the stdin descriptor being closed.
## Short Term Plans.
- [x] add the ziq as a name for the process.
- [x] use threads for the command event listner. (this will fix the slow jq parsing issue)
- [x] enable suspending the program. (with ctrl + z).
    - requires ctrl + z to be clicked twice.
- [ ] github ci/cd pipeline to build and release the project.
- [ ] support focus mode from window to window.
    - [ ] enable copy and pasting and selectin windows component
- [ ] Better Readme and example.

## Future Plans.
- [ ] support unicode.
- [ ] vim mode on the result window
- [ ] make the contents of the result window selectable and copyable
- [ ] autocomplete and suggestions.
- [ ] deploy it on homebrew and apt.
- [ ] horizontal scroll.
- [ ] Make the error window scrollable.
- [ ] further optimization.
    - if i knew the command is wrong no point of running jq even after new commands.
        (eq `.]` is an error and if another `]` added i don't need to pass this command to jq).
