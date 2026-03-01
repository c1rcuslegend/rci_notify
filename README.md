# 🔔 RCI Discord Notifier

Real-time Discord notifications when your RCI jobs **start**, **finish**, or **crash** — with error logs delivered straight to your channel.

---

## Functionality

| Event | Notification |
|-------|-------------|
| 🚀 **Job starts** | Job name, ID, partition, node, GPU count, array task info |
| ✅ **Job succeeds** | Job name, duration, partition, node |
| ❌ **Job fails** | Job name, duration, exit code, last 30 lines of **stdout** and **stderr** |

### Example Messages

**Job started:**
```
🚀 training_run started
┌──────────────────────────────┐
│ Job ID   : 12345678          │
│ Partition: h200              │
│ Node(s)  : h01               │
│ GPUs     : 4                 │
│ Array    : task 2 of 10      │
└──────────────────────────────┘
```

**Job succeeded:**
```
✅ training_run completed in 2h 15m 33s
┌──────────────────────────────┐
│ Job ID   : 12345678          │
│ Partition: h200              │
│ Node(s)  : h01               │
└──────────────────────────────┘
```

**Job failed:**
```
❌ training_run [task 3] failed after 0h 12m 45s
Exit code: 1

stdout (last 30 lines):
  Epoch 5/100, Step 847/2000
  Loss: 0.342

stderr (last 30 lines):
  RuntimeError: CUDA out of memory.
  Tried to allocate 2.00 GiB...
```

---

## Setup

### 1. Create a Discord Webhook

1. Open **Discord** → go to your server
2. Right-click the **channel** where you want notifications → **Edit Channel**
3. Go to **Integrations** → **Webhooks** → **New Webhook**
4. Give it a name (e.g. `SLURM Bot`), copy the **Webhook URL**

### 2. Find Your Discord User ID

This is needed so the bot can **@mention** you.

1. Open **Discord Settings** → **Advanced** → enable **Developer Mode**
2. Right-click your **username** anywhere in Discord → **Copy User ID**

### 3. Install `notify.sh`

Place the script in your **home directory** on the cluster:

```bash
cp notify.sh ~/notify.sh
```

Then edit the two configuration lines at the top:

```bash
# ── Configure these two lines ────────────────────────────────────────────────
DISCORD_WEBHOOK="https://discord.com/api/webhooks/YOUR_WEBHOOK_ID/YOUR_WEBHOOK_TOKEN"
DISCORD_USER_ID="YOUR_DISCORD_USER_ID"
# ─────────────────────────────────────────────────────────────────────────────
```

Replace:
- `YOUR_WEBHOOK_ID/YOUR_WEBHOOK_TOKEN` — with the Webhook URL you copied in step 1
- `YOUR_DISCORD_USER_ID` — with the User ID you copied in step 2

---

## Usage

Add **3 lines** to any SLURM job script:

```bash
source ~/notify.sh        # Load the notifier
notify_start              # Send "job started" notification

# ... your actual job code ...

notify_end $EXIT_CODE     # Send "job finished" notification
```

### Example

```bash
#!/bin/bash
#SBATCH --job-name=my_training
#SBATCH --partition=gpu
#SBATCH --gres=gpu:1
#SBATCH --mem=32G
#SBATCH --time=12:00:00
#SBATCH --output=out/my_training-%j.out
#SBATCH --error=out/my_training-%j.err

source ~/notify.sh
notify_start

echo "Starting training..."

python train.py --epochs 100 --lr 0.001

EXIT_CODE=$?

notify_end $EXIT_CODE
```


> **Note:** For array jobs, each task sends its own start/end notification with the task ID included.

---

## How It Works

- `notify_start` — sends a Discord message with job metadata (ID, partition, node, GPUs, array info)
- `notify_end $EXIT_CODE` — checks the exit code:
  - **`0`** → sends a ✅ success message with duration
  - **non-zero** → sends a ❌ failure message with exit code + last 30 lines of both `stdout` and `stderr` log files

### Log File Detection

The notifier automatically finds your log files regardless of what `--output` / `--error` format you use. It resolves paths using a priority chain:

1. **`scontrol show job`** — queries SLURM for the fully resolved absolute `StdOut`/`StdErr` paths (most reliable, works with any format)
2. **`SLURM_STDOUTMODE` / `SLURM_STDERRMODE`** env vars — expands `%` tokens (`%j`, `%x`, `%A`, `%a`, `%u`, `%N`, etc.) as a fallback
3. **`slurm-%j.out`** — SLURM's own default as a last resort

This means **any** `--output`/`--error` pattern works (notify us if some does not :DDD):

```bash
#SBATCH --output=out/%x-%j.out              # ✅ works
#SBATCH --output=/scratch/%u/logs/%j.log    # ✅ works (absolute path)
#SBATCH --output=out/%x-%A_%a.out           # ✅ works (array jobs)
#SBATCH --output=mylog.txt                  # ✅ works (no tokens)
```

### Discord Message Limits

Discord messages have a **2000 character limit**. The notifier reserves:
- ~700 chars for **stdout** tail
- ~900 chars for **stderr** tail
- ~200 chars for headers and metadata

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| Start works but end doesn't | Make sure `notify_end $EXIT_CODE` is after capturing `$?`, not inside a pipe |
| Logs show as empty | Check that your log files exist at the expected path. Run `scontrol show job $SLURM_JOB_ID` to see the resolved `StdOut`/`StdErr` paths |
| Mentions don't ping | Double-check your `DISCORD_USER_ID` is correct (must be a number) |

Please do not hesitate to contact us in case of any errors :)

---

## License

MIT — use it, share it, modify it.
