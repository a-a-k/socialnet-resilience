## Quick start

```bash
git clone https://github.com/your-org/socialnet-resilience
cd socialnet-resilience
chmod +x *.sh 00_helpers/*.sh

# baseline experiment (no replicas)
./pipeline_norepl.sh

# replica experiment
./pipeline_repl.sh
