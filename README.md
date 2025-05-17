## ZIQ

`ziq` is a lightweight command-line tool for processing JSON data on top of jq interactively

### Prerequisites

* **jq**: a powerful command-line JSON processor. If you don’t have `jq` installed, you can download it from the [official website](https://stedolan.github.io/jq/download/) or use your package manager:

  ```bash
  # macOS (using Homebrew)
  brew install jq

  # Ubuntu/Debian
  sudo apt-get update && sudo apt-get install -y jq

  # Fedora
  sudo dnf install jq
  ```

### Installation

1. **Download the binary** for your platform. from the [latest releases](https://github.com/abelkm99/ziq/releases) For example, on Apple Silicon (ARM) macOS download ziq_mac_arm.

2. **Rename the file** to `ziq`:

   ```bash
   mv ziq_mac_arm ziq
   ```

3. **Make it executable**: add sudo if necessary.

   ```bash
   chmod +x ziq
   ```

4. **Move it into your `PATH`** so you can run it from anywhere. For example:

   ```bash
   sudo mv ziq /usr/local/bin/
   ```

   > You can also copy it into `~/bin` or another directory in your `PATH`.

### Usage

Pass a JSON file (or any JSON stream) to `ziq` via stdin:

```bash
ziq < data.json
```

**Example**: filter and transform JSON input using your preferred `jq` filters:

```bash
cat data.json | ziq
```

```bash
ziq < ./data.json
```



### Contributing

Contributions are welcome! Feel free to open issues or pull requests on the [GitHub repository](https://github.com/abelkm99/ziq).
