import json
import glob
import sys

def aggregate_stats(pattern):
    total_allocs = 0
    sampled_allocs = 0
    sampled_live = 0
    total_files = 0
    
    files = glob.glob(pattern)
    for f in files:
        try:
            with open(f, 'r') as fp:
                data = json.load(fp)
                total_allocs += data.get('total_allocs', 0)
                sampled_allocs += data.get('sampled_allocs', 0)
                sampled_live += data.get('sampled_live_allocs_estimate', 0)
                total_files += 1
        except:
            continue
            
    print(f"--- {pattern} ---")
    print(f"Processes tracked: {total_files}")
    print(f"Total Allocs:      {total_allocs}")
    print(f"Sampled Allocs:    {sampled_allocs}")
    if total_allocs > 0:
        print(f"Sample Rate:       {sampled_allocs/total_allocs*100:.4f}%")
        print(f"Sampled Live Est:  {sampled_live}")
    else:
        print("Sample Rate:       0.0000%")

aggregate_stats("/tmp/curl_hash.json.*")
aggregate_stats("/tmp/curl_poisson.json.*")

