//
// Copyright (c) 2024 PADL Software Pty Ltd
//
// Licensed under the Apache License, Version 2.0 (the License);
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an 'AS IS' BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

public enum AttributeValueFilter: Sendable {
  // match any value for this attribute type
  case matchAny
  // match any value whose index matches the provided index
  case matchAnyIndex(UInt64)
  // match any value whose index matches the provided value
  case matchIndex(any Value)
  // match value which matches exactly
  case matchEqual(any Value)
  case matchEqualWithSubtype((AttributeSubtype?, any Value))
  // match value which matches exactly, relative to provided index
  case matchRelative((any Value, UInt64))
  case matchRelativeWithSubtype((AttributeSubtype?, any Value, UInt64))
}
