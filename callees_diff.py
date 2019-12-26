#!/bin/python

import sys

def read_callees(file_name, callees):
    with open(file_name) as f:
        for line in f:
            #print(line)
            entries = line.replace("\n", "").split(",")
            if len(entries) == 1:
                callee = int(entries[0], 16)
                callees[callee] = []
            else:
                bbs = []
                for entry in entries:
                    if len(entry) > 0:
                        e = entry.split(":")
                        c = int(e[1])
                        bbs.append(c)
                callees[callee].append(bbs)

def pearson(x,y):
  n=len(x)
  vals=range(n)

  sumx=sum([float(x[i]) for i in vals])
  sumy=sum([float(y[i]) for i in vals])

  sumxSq=sum([x[i]**2.0 for i in vals])
  sumySq=sum([y[i]**2.0 for i in vals])

  pSum=sum([x[i]*y[i] for i in vals])
  # Calculating Pearson correlation
  num=pSum-(sumx*sumy/n)
  den=((sumxSq-pow(sumx,2)/n)*(sumySq-pow(sumy,2)/n))**.5
  if den == 0:
    if num == 0: return 1
    else: return 0
  r=num/den
  return r

def calc_diff(callees):
    pearsons = []
    for callee, bbs in callees.items():
        for bb in bbs:
            s = sum(bb)
            for i in range(len(bb)):
                bb[i] /= float(s)

    for callee, bbs in callees.items():
        for i in range(len(bbs)):
            for j in range(i+1, len(bbs)):
                bb1 = bbs[i]
                bb2 = bbs[j]
                p = pearson(bb1, bb2)
                #print("bb1: "+str(bb1))
                #print("bb2: "+str(bb2))
                #print("p: "+str(p))
                pearsons.append(p)
    return sum(pearsons) / len(pearsons)

if __name__ == "__main__":
    nvbit_file_name = sys.argv[1]

    callees = dict()
    read_callees(nvbit_file_name, callees)
    #print(callees)
    print(calc_diff(callees))
