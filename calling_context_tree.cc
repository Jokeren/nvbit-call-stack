#include "calling_context_tree.h"

#include <iostream>

int main() {
  CallingContextTree cct;
  // <w1>: <f1, 2> -> <f2, 3> -> <f4> : b2
  //                  <f2, 4> -> <f4> : b3
  //                  <f2, 3> -> <f4> : b2
  //       <f1, 3> -> <f5, 4> : b3
  cct.call(1, 1, 2);
  cct.call(1, 2, 3);
  cct.block(1, 4, 2);
  std::cout << cct.to_string() << std::endl;
  cct.ret(1);
  cct.call(1, 2, 4);
  cct.block(1, 4, 3);
  std::cout << cct.to_string() << std::endl;
  cct.ret(1);
  cct.call(1, 2, 3);
  cct.block(1, 4, 2);
  std::cout << cct.to_string() << std::endl;
  cct.ret(1);
  cct.ret(1);
  cct.call(1, 1, 3);
  cct.block(1, 5, 3);
  std::cout << cct.to_string() << std::endl;
  // <w2>: <f1, 2> -> <f2, 4> -> <f4> : b1
  cct.call(2, 1, 2);
  cct.call(2, 2, 4);
  cct.block(2, 4, 1);
  std::cout << cct.to_string() << std::endl;
  return 0;
}
