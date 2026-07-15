# Manually configuring Qdiscs on Marvell

```
tc qdisc add dev xe0 parent root handle 9000 mqprio num_tc 3 map 0 0 1 2 0 0 0 0 0 0 0 0 0 0 0 0 queues 2@0 1@2 1@3 hw 1
tc qdisc replace dev xe0 parent 9000:4 cbs hicredit 26 locredit -262 sendslope -982912 idleslope 20000 offload 1
```

# Add FDB entry

```
bridge fdb add 8c:1f:64:e8:90:27 dev xe0 master static
```

